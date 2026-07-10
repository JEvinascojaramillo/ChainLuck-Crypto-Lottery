// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@chainlink/contracts/src/v0.8/vrf/VRFConsumerBaseV2.sol";
import "@chainlink/contracts/src/v0.8/vrf/interfaces/VRFCoordinatorV2Interface.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ChainLuck - Loteria descentralizada con Chainlink VRF
/// @notice v2: pull-payments para fees, timeout de rescate, struct packing
contract ChainLuck is VRFConsumerBaseV2, Ownable, ReentrancyGuard {
    VRFCoordinatorV2Interface private immutable i_vrfCoordinator;
    bytes32 private immutable i_keyHash;
    uint64 private immutable i_subscriptionId;
    uint32 private constant CALLBACK_GAS_LIMIT = 100_000;
    uint16 private constant REQUEST_CONFIRMATIONS = 3;
    uint32 private constant NUM_WORDS = 1;

    /// @dev Ventana de gracia antes de permitir refund si VRF nunca responde
    uint256 public constant VRF_TIMEOUT = 1 hours;

    enum LotteryState { CLOSED, OPEN, CALCULATING }

    // --- FIX #8: struct reordenado para storage packing ---
    // winner (address, 20 bytes) + prizeClaimed (bool, 1 byte) + state (enum, 1 byte)
    // ahora comparten un solo slot de 256 bits en vez de 3 slots separados.
    struct Round {
        uint256 roundId;
        uint256 ticketPrice;
        uint256 startTime;
        uint256 endTime;
        address[] players;
        uint256 prizePool;
        uint256 vrfRequestId;
        uint256 prize;        // FIX #7: se guarda una sola vez, no se recalcula en claimPrize
        address winner;       // \
        bool prizeClaimed;    //  } empaquetados en un solo slot
        LotteryState state;   // /
    }

    uint256 public currentRoundId;
    uint256 public ticketPrice;
    uint256 public ownerFeePercent;

    mapping(uint256 => Round) public rounds;
    mapping(uint256 => uint256) public vrfRequestToRound;
    mapping(uint256 => mapping(address => uint256)) public ticketsByPlayer;

    // FIX #2: pull-payment. En vez de mandar ETH dentro del callback de VRF,
    // acumulamos balances y cada quien retira cuando quiera. Esto evita que
    // un owner/contrato que rechace ETH bloquee el callback y congele fondos
    // de todos los jugadores.
    mapping(address => uint256) public pendingWithdrawals;

    event LotteryOpened(uint256 indexed roundId, uint256 ticketPrice, uint256 timestamp);
    event TicketPurchased(uint256 indexed roundId, address indexed player, uint256 ticketsBought, uint256 totalTickets);
    event LotteryClosed(uint256 indexed roundId, uint256 totalPlayers, uint256 prizePool);
    event RandomWordsRequested(uint256 indexed roundId, uint256 vrfRequestId);
    event WinnerSelected(uint256 indexed roundId, address indexed winner, uint256 prize); // FIX #1: ahora SI se emite
    event PrizeClaimed(uint256 indexed roundId, address indexed winner, uint256 amount);
    event TicketPriceUpdate(uint256 oldPrice, uint256 newPrice);
    event FeeUpdate(uint256 feeOld, uint256 feeNew);
    event Withdrawal(address indexed account, uint256 amount);
    event RoundRefunded(uint256 indexed roundId, uint256 totalRefunded); // FIX #3

    error ChainLuck_LotteryNotOpen();
    error ChainLuck_LotteryNotClosed();
    error ChainLuck_WrongTicketPrice();
    error ChainLuck_NoPlayers();
    error ChainLuck_NotWinner();
    error ChainLuck_PrizeAlreadyClaimed();
    error ChainLuck_NoPrizeAvailable();
    error ChainLuck_InvalidFee();
    error ChainLuck_TransferFailed();
    error ChainLuck_NothingToWithdraw();
    error ChainLuck_NotCalculating();
    error ChainLuck_TimeoutNotReached(); // FIX #3

    constructor(
        address _vrfCoordinator,
        bytes32 _keyHash,
        uint64 _subscriptionId,
        uint256 _ticketPrice,
        uint256 _ownerFeePercent
    )
        VRFConsumerBaseV2(_vrfCoordinator)
        Ownable(msg.sender)
    {
        if (_ownerFeePercent > 10) revert ChainLuck_InvalidFee();

        i_vrfCoordinator = VRFCoordinatorV2Interface(_vrfCoordinator);
        i_keyHash = _keyHash;
        i_subscriptionId = _subscriptionId;
        ticketPrice = _ticketPrice;
        ownerFeePercent = _ownerFeePercent;
    }

    function openLottery() external onlyOwner {
        Round storage current = rounds[currentRoundId];
        if (current.state != LotteryState.CLOSED && currentRoundId != 0) {
            revert ChainLuck_LotteryNotClosed();
        }

        // FIX #11: unchecked, nunca desborda incrementando de a uno
        unchecked {
            currentRoundId++;
        }

        Round storage newRound = rounds[currentRoundId];
        newRound.roundId = currentRoundId;
        newRound.ticketPrice = ticketPrice;
        newRound.startTime = block.timestamp;
        newRound.state = LotteryState.OPEN;

        emit LotteryOpened(currentRoundId, ticketPrice, block.timestamp);
    }

    function buyTicket() external payable nonReentrant {
        Round storage round = rounds[currentRoundId];

        if (round.state != LotteryState.OPEN) revert ChainLuck_LotteryNotOpen();
        if (msg.value != round.ticketPrice) revert ChainLuck_WrongTicketPrice();

        round.players.push(msg.sender);
        round.prizePool += msg.value;

        // FIX #10: unchecked, ya se valido msg.value == ticketPrice arriba,
        // no hay forma realista de desbordar un contador de tickets
        uint256 newTicketCount;
        unchecked {
            newTicketCount = ticketsByPlayer[currentRoundId][msg.sender] + 1;
        }
        ticketsByPlayer[currentRoundId][msg.sender] = newTicketCount;

        emit TicketPurchased(
            currentRoundId,
            msg.sender,
            newTicketCount,
            round.players.length
        );
    }

    function closedLotteryAndRequestWinner() external onlyOwner {
        Round storage round = rounds[currentRoundId];

        if (round.state != LotteryState.OPEN) revert ChainLuck_LotteryNotOpen();

        // FIX #9: cachear length en memoria, un solo SLOAD
        uint256 playerCount = round.players.length;
        if (playerCount == 0) revert ChainLuck_NoPlayers();

        round.state = LotteryState.CALCULATING;
        round.endTime = block.timestamp;

        uint256 requestId = i_vrfCoordinator.requestRandomWords(
            i_keyHash,
            i_subscriptionId,
            REQUEST_CONFIRMATIONS,
            CALLBACK_GAS_LIMIT,
            NUM_WORDS
        );
        round.vrfRequestId = requestId;
        vrfRequestToRound[requestId] = currentRoundId;

        emit LotteryClosed(currentRoundId, playerCount, round.prizePool);
        emit RandomWordsRequested(currentRoundId, requestId);
    }

    /// @dev FIX #2 + #4: sin external call aqui (pull-payment), y CEI estricto.
    /// Esto es lo mas importante del contrato: si esto revierte, VRF no
    /// reintenta y la ronda queda trabada para siempre. Por eso NO debe
    /// haber ninguna operacion que pueda fallar por culpa de terceros
    /// (como un owner rechazando ETH).
    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords)
        internal
        override
    {
        uint256 roundId = vrfRequestToRound[requestId];
        Round storage round = rounds[roundId];

        uint256 playerCount = round.players.length;
        uint256 winnerIndex = randomWords[0] % playerCount;
        address winner = round.players[winnerIndex];

        uint256 fee = (round.prizePool * ownerFeePercent) / 100;
        uint256 prize = round.prizePool - fee;

        round.winner = winner;
        round.prize = prize;
        round.state = LotteryState.CLOSED;

        // acumular en vez de transferir directamente
        if (fee > 0) {
            pendingWithdrawals[owner()] += fee;
        }

        emit WinnerSelected(roundId, winner, prize);
    }

    function claimPrize(uint256 roundId) external nonReentrant {
        Round storage round = rounds[roundId];

        if (round.winner != msg.sender) revert ChainLuck_NotWinner();
        if (round.prizeClaimed) revert ChainLuck_PrizeAlreadyClaimed();
        if (round.state != LotteryState.CLOSED) revert ChainLuck_NoPrizeAvailable();

        // FIX #7: prize ya viene calculado desde fulfillRandomWords
        uint256 prize = round.prize;
        round.prizeClaimed = true;

        (bool ok, ) = msg.sender.call{value: prize}("");
        if (!ok) revert ChainLuck_TransferFailed();

        emit PrizeClaimed(roundId, msg.sender, prize);
    }

    /// @notice Retira fees acumulados (owner) u otros balances pendientes.
    /// @dev FIX #2: patron pull-payment, separado de la logica de VRF.
    function withdraw() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        if (amount == 0) revert ChainLuck_NothingToWithdraw();

        pendingWithdrawals[msg.sender] = 0;

        (bool ok, ) = msg.sender.call{value: amount}("");
        if (!ok) revert ChainLuck_TransferFailed();

        emit Withdrawal(msg.sender, amount);
    }

    /// @notice FIX #3: si Chainlink VRF nunca responde (ej. falta LINK en la
    /// suscripcion), cualquiera puede activar el reembolso despues del timeout.
    /// Evita que los fondos de los jugadores queden atrapados para siempre.
    function refundIfVrfFailed(uint256 roundId) external nonReentrant {
        Round storage round = rounds[roundId];

        if (round.state != LotteryState.CALCULATING) revert ChainLuck_NotCalculating();
        if (block.timestamp < round.endTime + VRF_TIMEOUT) revert ChainLuck_TimeoutNotReached();

        round.state = LotteryState.CLOSED;

        uint256 pricePerTicket = round.ticketPrice;
        uint256 playerCount = round.players.length;
        uint256 totalRefunded;

        for (uint256 i = 0; i < playerCount; ) {
            address player = round.players[i];
            uint256 tickets = ticketsByPlayer[roundId][player];

            if (tickets > 0) {
                ticketsByPlayer[roundId][player] = 0;
                uint256 refundAmount = tickets * pricePerTicket;
                pendingWithdrawals[player] += refundAmount;
                totalRefunded += refundAmount;
            }

            unchecked {
                ++i;
            }
        }

        emit RoundRefunded(roundId, totalRefunded);
    }

    function setTicketPrice(uint256 _newPrice) external onlyOwner {
        Round storage round = rounds[currentRoundId];
        if (round.state == LotteryState.OPEN) revert ChainLuck_LotteryNotClosed();

        emit TicketPriceUpdate(ticketPrice, _newPrice);
        ticketPrice = _newPrice;
    }

    function setOwnerFee(uint256 _newFee) external onlyOwner {
        if (_newFee > 10) revert ChainLuck_InvalidFee();

        emit FeeUpdate(ownerFeePercent, _newFee);
        ownerFeePercent = _newFee;
    }

    function getCurrentRoundPlayers() external view returns (address[] memory) {
        return rounds[currentRoundId].players;
    }

    function getCurrentRoundInfo() external view returns (
        uint256 roundId,
        uint256 price,
        uint256 playerCount,
        uint256 prizePool,
        LotteryState state
    ) {
        Round storage r = rounds[currentRoundId];
        return (r.roundId, r.ticketPrice, r.players.length, r.prizePool, r.state);
    }

    function getPlayerTickets(uint256 roundId, address player) external view returns (uint256) {
        return ticketsByPlayer[roundId][player];
    }

    function getRoundWinner(uint256 roundId) external view returns (address) {
        return rounds[roundId].winner;
    }

    receive() external payable {}
}

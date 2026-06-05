// SPDX-License-identifier: MIT
pragma solidity ^0.8.19;

import "@chainlink/contracts/src/v0.8/vrf/VRFConsumerBaseV2.sol";
import "@chainlink/contracts/src/v0.8/vrf/interfaces/VRFCoordinatorV2Interface.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract ChainLuck is VRFConsumerBaseV2, Ownable, ReentrancyGuard {
    VRFCoordinatorV2Interface private immutable i_vrfCoordinator;
    bytes32 private immutable i_keyHash;
    uint64 private immutable i_subscriptionId;
    uint32 private constant CALLBACK_GAS_LIMIT = 100_000;
    uint16 private constant REQUEST_CONFIRMATIONS = 3;
    uint32 private constant NUM_WORDS = 1;

    enum LotteryState { CLOSED, OPEN, CALCULATING}
    struct Round {
        uint256 roundId;
        uint256 ticketPrice;
        uint256 startTime;
        uint256 endTime;
        address[] players;
        address winner;
        uint256 prizePool;
        uint256 vrfRequestId;
        bool prizeClaimed;
        LotteryState state;
    }
    uint256 public currentRoundId;
    uint256 public ticketPrice;
    uint256 public ownerFeePercent;

    mapping(uint256 => Round) public rounds;
    mapping(uint256 => uint256) public vrfRequestToRound;
    mapping(uint256 => mapping (address => uint256)) public ticketsByPlayer;

    event LotteryOpened(uint256 indexed roundId, uint256 ticketPrice, uint256 timestamp);
    event TicketPurchased(uint256 indexed roundId, address indexed player, uint256 ticketsBought, uint256 totalTickets);
    event LotteryClosed(uint256 indexed roundId, uint256 totalPlayers, uint256 PrizePool);
    event RandomWordsRequested(uint256 indexed roundId, uint256 vrfRequestId);
    event WinnerSelect(uint256 indexed roundId, address indexed winner, uint256 prize);
    event PrizeClaimed(uint256 indexed roundId, address indexed winner, uint256 amount);
    event TicketPriceUpdate(uint256 oldPrice, uint256 newPrice);
    event FeeUpdate(uint256 feeOld, uint256 feeNew);

    error ChainLuck_LotteryNotOpen();
    error ChainLuck_LotteryNotClosed();
    error ChainLuck_WrongTicketPrice();
    error ChainLuck_NoPlayers();
    error ChainLuck_NotWinner();
    error ChainLuck_PrizeAlreadyClaimed();
    error ChainLuck_NoPrizeAvailable();
    error ChainLuck_InvalidFee();
    error ChainLuck_TransferFailed();

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
        if (current.state != LotteryState.CLOSED && currentRoundId !=0) {
            revert ChainLuck_LotteryNotClosed();
        }
        currentRoundId++;
        Round storage newRound = rounds[currentRoundId];
        newRound.roundId = currentRoundId;
        newRound.ticketPrice = ticketPrice;
        newRound.startTime = block.timestamp;
        newRound.state = LotteryState.OPEN;

        emit LotteryOpened(currentRoundId, ticketPrice, block.timestamp);
    }
    function buyTicket() external payable nonReentrant {
        Round storage round = rounds[currentRoundId];

        if(round.state != LotteryState.OPEN) revert ChainLuck_LotteryNotOpen();
        if(msg.value != round.ticketPrice) revert ChainLuck_WrongTicketPrice();

        round.players.push(msg.sender);
        round.prizePool += msg.value;
        ticketsByPlayer[currentRoundId][msg.sender]++;

        emit TicketPurchased(
        currentRoundId,
        msg.sender,
        ticketsByPlayer[currentRoundId][msg.sender],
        round.players.length
        );   
         }

         function closedLotteryAndRequestWinner() external onlyOwner{
            Round storage round = rounds[currentRoundId];
            
            if (round.state != LotteryState.OPEN) revert ChainLuck_LotteryNotOpen();
            if (round.players.length == 0) revert ChainLuck_NoPlayers();

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

            emit LotteryClosed(currentRoundId, round.players.length, round.prizePool);
            emit RandomWordsRequested(currentRoundId, requestId);
         }
        
         function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords)
        internal
        override
    {
        uint256 roundId = vrfRequestToRound[requestId];
        Round storage round = rounds[roundId];

        uint256 winnerIndex = randomWords[0] % round.players.length;
        address winner = round.players[winnerIndex];

        uint256 fee = (round.prizePool * ownerFeePercent)/100;
        uint256 prize = round.prizePool - fee;

        round.winner = winner;
        round.state = LotteryState.CLOSED;

        if (fee > 0) {
            (bool feeOk,) = owner().call{value: fee}("");
            if(!feeOk) revert ChainLuck_TransferFailed();
        }
        }
        function claimPrize(uint256 roundId) external nonReentrant {
            Round storage round = rounds[roundId];

            if(round.winner != msg.sender) revert ChainLuck_NotWinner();
            if(round.prizeClaimed) revert ChainLuck_PrizeAlreadyClaimed();
            if(round.state != LotteryState.CLOSED) revert ChainLuck_NoPrizeAvailable();

            uint256 fee =(round.prizePool*ownerFeePercent)/100;
            uint256 prize = round.prizePool - fee;

            round.prizeClaimed = true;

            (bool ok,) = msg.sender.call{value: prize}("");
            if(!ok) revert ChainLuck_TransferFailed();

            emit PrizeClaimed(roundId, msg.sender, prize);
        }

        function setTicketPrice(uint256 _newPrice) external onlyOwner {
            Round storage round = rounds[currentRoundId];
            if(round.state == LotteryState.OPEN) revert ChainLuck_LotteryNotClosed();
            emit TicketPriceUpdate(ticketPrice,_newPrice);
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

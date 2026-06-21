# 🎲 On-Chain Guayabita (Hybrid Module) · ChainLuck

Welcome to the **Guayabita** module—a beloved, traditional Colombian dice game completely re-engineered for the Web3 ecosystem. This smart contract is 100% decentralized, transparent, and secure, utilizing a cutting-edge hybrid lobby architecture designed to maximize on-chain liquidity while preserving the raw social and competitive essence of the original game.

Developed under the infrastructure of **VJ Research** for the **ChainLuck** platform.

---

## 🚀 Key Features

* **100% On-Chain & Decentralized:** All game logic, phase turn-management, and wagering are processed directly on the Polygon blockchain using **USDC** (6 decimals).
* **Tamper-Proof Randomness via Chainlink VRF v2:** Powered by Chainlink's decentralized oracle (`VRFConsumerBaseV2`). This ensures that every dice roll is mathematically unpredictable and publicly auditable, eliminating any house edge or manipulation risks.
* **Innovative Hybrid Matchmaking Architecture:**
    1. **Public Games (Quick-Match):** An automated system where users simply select their desired entry fee (the *casado*). The contract handles grouping by tier and automatically triggers the game sequence once the maximum capacity of **6 players** is reached.
    2. **Private Games (Closed Rooms):** Tailored for communities, Content Creators, and friendly tournaments. The *Host* can customize parameters to their liking (Casado, Minimum Bet, and Room Capacity ranging from 2 to 6 players), securing entry via a cryptographic pass-code hash (`accessCode`).
* **Anti-DoS Security (Pull Pattern Architecture):** Winnings from high-stakes dice phases are stored safely in an internal ledger rather than being pushed instantly. This eliminates gas-outage vulnerabilities and reentrancy vectors, allowing users to withdraw their earnings securely through a dedicated `claimWinnings` withdrawal function.
* **Stuck-Funds Protection (Lobby Timeout Mechanism):** Features a dedicated public lobby rescue function (`refundEmptyPublicGame`). If an automated public room fails to fill up within 24 hours, users can safely reclaim their locked assets.
* **Native Monetization (5% Protocol Fee):** The protocol automatically deducts a 5% fee from the accumulated final pot upon the resolution of each game, streaming passive platform revenue directly to the contract `owner`.

---

## 📜 Implemented Game Rules

1. **The Casado (Ante):** Every participant entering a table deposits a fixed initial amount (the *casado*) to form the starting pot (`pot`).
2. **First Roll:** On their turn, the active player requests a random number for their first die:
    * **Rolling a 1 or a 6:** The player instantly loses their turn. The contract checks their balance and allowance; if they have sufficient liquidity, an automated penalty (another *casado*) is swept directly into the pot. If they lack the funds to pay the penalty, they are **immediately expelled** from the table to maintain optimal game pacing.
    * **Rolling a 2, 3, 4, or 5:** The betting window unlocks.
3. **The Bet:** The player sets their wager (minimum of the room's `minBet`, maximum of the total current pot). Their USDC is transferred preventively into the contract's escrow.
4. **Second Roll (The Showdown):** The player rolls the second die:
    * **Die 2 > Die 1 (WIN):** The player recovers their escrowed wager and claims an equivalent amount directly from the pot.
    * **Die 2 ≤ Die 1 (LOSS):** Their wager is permanently absorbed into the accumulated pot, raising the stakes for the remaining players.
5. **Game Resolution:** The table concludes when the pot reaches `0` or when the Host manually terminates the session (exclusive to private rooms). The remaining pot—after deducting the 5% protocol fee—is distributed evenly among all active remaining players.

---

## 🛠️ Core Smart Contract Functions

### Public Lobbies (Automated)
* `joinQuickMatch(uint256 _casado)`: Instantly matches the user into an available public lobby of the specified tier, or seamlessly initializes a new one if all current rooms are full.
* `refundEmptyPublicGame(uint256 _gameId)`: Allows trapped players or the contract owner to dissolve a room and receive a full refund if the 6-player requirement has not been met within a 24-hour window.

### Private Lobbies (Hosted)
* `createPrivateGame(uint256 _casado, uint256 _minBet, uint8 _maxPlayers, string _secretCode)`: Initializes a highly customizable closed room, generating a secure Keccak256 hash from the host's alphanumeric passcode.
* `joinPrivateGame(uint256 _gameId, string _secretCode)`: Validates the plaintext input against the stored hash to authorize access for incoming players.
* `startPrivateGame(uint256 _gameId)`: Authorizes the host to kick off the game loop once the minimum player requirement (at least 2 players) is satisfied.
* `closeGame(uint256 _gameId)`: Permits manual termination by the host to wind down the session and fairly distribute any remaining pot.

### Gameplay Core & Claims
* `rollFirst(uint256 _gameId)` & `placeBet(uint256 _gameId, uint256 _amount)`: Operational turn-handlers controlling dice execution and escrow inputs.
* `claimWinnings(uint256 _gameId)`: Executes a secure, low-overhead withdrawal of accumulated winnings straight to the user's external wallet.

---

## 💻 Frontend Integration

The contract views and storage layouts are heavily optimized to interface cleanly with Web3 React hooks (*Ethers.js*, *Viem*, or *Wagmi*), exposing comprehensive game states in a single, lightweight RPC call:

```solidity
function getGameInfo(uint256 _gameId) external view returns (
    address host,
    uint256 casado,
    uint256 minBet,
    uint256 pot,
    uint8 maxPlayers,
    uint8 playerCount,
    uint8 currentTurnIdx,
    uint8 dice1,
    uint8 dice2,
    uint256 currentBet,
    GameState state,
    bool isPrivate
);

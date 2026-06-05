# 🍀 ChainLuck

<div align="center">

![ChainLuck Banner](./assets/chainluck-banner.png)

**Provably fair, fully on-chain lottery — no house, no trust required.**

[![Solidity](https://img.shields.io/badge/Solidity-0.8.19-363636?logo=solidity)](https://soliditylang.org)
[![Chainlink VRF](https://img.shields.io/badge/Chainlink-VRF%20v2-375BD2?logo=chainlink)](https://docs.chain.link/vrf)
[![Polygon](https://img.shields.io/badge/Network-Polygon-8247E5?logo=polygon)](https://polygon.technology)
[![OpenZeppelin](https://img.shields.io/badge/OpenZeppelin-5.x-4E5EE4)](https://openzeppelin.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)

[Live Demo](#) · [Contract on Polygonscan](#) · [Docs](#how-it-works)

</div>

---

Traditional lotteries ask you to trust a company. ChainLuck asks you to trust math.

The winner is picked by **Chainlink VRF v2** — a cryptographic randomness protocol where the output is generated and verified on-chain. Not even the contract owner can predict or influence it. Every ticket, every round, every winner lives on Polygon forever.

---

## How it works

```
buy ticket  →  round closes  →  Chainlink VRF fires  →  winner picked  →  prize claimed
     ↑                                  ↑
immutable contract            cryptographically unmanipulable
```

### Round lifecycle

| Step | Function | Who calls it |
|---|---|---|
| Open a new round | `openLottery()` | Owner |
| Buy a ticket | `buyTicket()` | Anyone |
| Close sales & request randomness | `closeLotteryAndRequestWinner()` | Owner |
| Receive random number & pick winner | `fulfillRandomWords()` | Chainlink VRF |
| Claim prize | `claimPrize(roundId)` | Winner |

### Prize split

```
Prize pool
├── 95%  →  Winner
└──  5%  →  Protocol  (owner-configurable, hard-capped at 10%)
```

---

## Stack

| | |
|---|---|
| Smart contract | Solidity 0.8.19 |
| Randomness | Chainlink VRF v2 |
| Network | Polygon (low gas fees) |
| Security | OpenZeppelin — Ownable, ReentrancyGuard |
| Tooling | Hardhat · ethers.js |
| Frontend | Vanilla JS · MetaMask |
| Pricing | CoinGecko API (live MATIC/USD) |

---

## Getting started

**Prerequisites:** Node.js ≥ 18, a funded wallet on Polygon, and an active [Chainlink VRF subscription](https://vrf.chain.link).

```bash
git clone https://github.com/JEvinascojaramillo/ChainLuck.git
cd ChainLuck
npm install
cp .env.example .env   # fill in your keys
```

### Deploy to Mumbai testnet

```bash
npx hardhat run scripts/deploy.js --network mumbai
```

### Deploy to Polygon mainnet

```bash
npx hardhat run scripts/deploy.js --network polygon
```

The deploy script prints the Polygonscan verification command and the exact line to update in the frontend automatically.

### Environment variables

```env
PRIVATE_KEY=                  # your wallet private key (no 0x prefix)
MUMBAI_RPC_URL=               # e.g. https://rpc-mumbai.maticvigil.com
POLYGON_RPC_URL=              # e.g. https://polygon-rpc.com
POLYGONSCAN_API_KEY=          # from polygonscan.com/myapikey
VRF_SUBSCRIPTION_ID=          # from vrf.chain.link
```

> Never commit `.env` to version control. It's already in `.gitignore`.

---

## Chainlink VRF addresses

| Network | Coordinator | Key Hash |
|---|---|---|
| Polygon Mainnet | `0xAE975071...858067` | `0x6e099d64...de400b9e` |
| Mumbai Testnet | `0x7a1BaC17...659aA5` | `0x4b09e658...bb02c003` |

Full addresses in `hardhat.config.js` and `scripts/deploy.js`.

---

## Contract API

```solidity
// Anyone
buyTicket()                                        // send exactly ticketPrice in MATIC
claimPrize(uint256 roundId)                        // winner only
getCurrentRoundInfo()  returns (id, price, players, pool, state)
getCurrentRoundPlayers() returns (address[])
getPlayerTickets(uint256 roundId, address player)  returns (uint256)
getRoundWinner(uint256 roundId)                    returns (address)

// Owner only
openLottery()
closeLotteryAndRequestWinner()
setTicketPrice(uint256 newPrice)                   // between rounds only
setOwnerFee(uint256 newFee)                        // max 10%, enforced on-chain
```

---

## Security

- `ReentrancyGuard` on all MATIC transfer paths
- `Ownable` for privileged functions
- Custom errors instead of revert strings (cheaper gas, clearer stack traces)
- Fee ceiling hard-coded at 10% — can't be bypassed without redeploying
- Ticket price is locked while a round is active
- Winner selection fully delegated to Chainlink VRF — owner has zero influence

> No third-party audit yet. Use on mainnet at your own risk.

---

## Roadmap

- [x] Core contract + Chainlink VRF v2
- [x] Frontend with live MATIC/USD pricing
- [x] Testnet deployment
- [ ] Full Hardhat test suite
- [ ] Security audit
- [ ] Polygon mainnet launch
- [ ] Chainlink Automation for trustless round management
- [ ] Multi-token support (USDC, WETH)

---

## Contributing

Issues and PRs welcome. For significant changes, open an issue first.

```bash
git checkout -b feat/your-idea
git commit -m "feat: your idea"
git push origin feat/your-idea
# → open a pull request
```

---

**Juan Esteban Vinasco** · [@VJ_Research](https://twitter.com/VJ_Research) · Building in Web3 from Medellín 🇨🇴

<sub>MIT License · Powered by Chainlink VRF · Deployed on Polygon</sub>

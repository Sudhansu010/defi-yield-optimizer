# DeFi Yield Optimizer

> Built for Encode Club's **Programmable Money Hackathon** on Circle's **Arc L1**
> Track: **DeFi**

An automated tool that moves USDC between DeFi pools/protocols (Aave, Compound,
Uniswap, Curve) to always chase the best available yield — continuously
monitoring APYs and rebalancing while enforcing a per-strategy risk cap.

## How it works

- **`YieldOptimizerVault.sol`** — users deposit USDC and receive shares
  (ERC-4626-style accounting). The vault tracks a set of registered strategy
  adapters and can rebalance funds from the lowest-APY strategy into the
  highest-APY one whenever the improvement clears a minimum threshold. A
  `maxAllocationBps` cap (default 60%) stops the vault from putting everything
  into one pool no matter how attractive its yield looks.
- **`MockYieldStrategy.sol`** — one adapter per protocol (Aave / Compound /
  Uniswap / Curve). Each adapter reports a live APY and accrues yield over time
  from a pre-funded reserve, fully backed 1:1 by real testnet USDC. On mainnet,
  each of these would be swapped for a thin wrapper that calls the real
  protocol's deposit/withdraw functions directly.
- **`frontend/index.html`** — a single-file dashboard (MetaMask + ethers.js)
  to deposit, withdraw, and trigger a rebalance live, for demos.

## Why Arc

Arc is Circle's L1 with USDC as native gas and sub-second finality — ideal for
a yield optimizer since strategy rebalancing needs fast, cheap, dollar-denominated
transactions rather than volatile gas costs eating into yield.

## Project structure

```
contracts/
  YieldOptimizerVault.sol
  interfaces/
    IERC20.sol
    IYieldStrategy.sol
  strategies/
    MockYieldStrategy.sol
scripts/
  deploy.js
frontend/
  index.html
hardhat.config.js
package.json
```

## Setup

### 1. Get testnet USDC
Go to https://faucet.circle.com, select **Arc Testnet**, and request USDC
(1 USDC/day). You'll need enough to seed each strategy's yield reserve
(default: 50 USDC per strategy in `scripts/deploy.js`) plus whatever you want
to deposit for the demo.

### 2. Find the Arc testnet USDC address + RPC URL
Check https://docs.arc.network for the current Arc testnet USDC contract
address and RPC endpoint (these can change while Arc is in public testnet).

### Option A — Deploy via Remix (fastest, no local setup)
1. Go to https://remix.ethereum.org and create the same folder structure,
   pasting in the 4 `.sol` files.
2. Compile with Solidity `0.8.24`.
3. In the **Deploy & Run** tab, set environment to **Injected Provider —
   MetaMask**, and switch MetaMask to the Arc testnet (add it as a custom
   network using the RPC URL + chain ID from docs.arc.network).
4. Deploy `YieldOptimizerVault` with the Arc testnet USDC address as the
   constructor argument.
5. Deploy `MockYieldStrategy` four times (once per protocol name), passing:
   `name`, `usdcAddress`, `vaultAddress`, `yourWalletAddress` (as keeper),
   and an initial APY in bps (e.g. `380` = 3.80%).
6. Call `vault.addStrategy(strategyAddress)` for each of the 4 strategies.
7. Send some testnet USDC directly to each strategy's address (this is its
   "yield reserve" that funds simulated interest payouts).

### Option B — Deploy via Hardhat
```bash
npm install
cp .env.example .env   # fill in PRIVATE_KEY and ARC_TESTNET_RPC_URL
npm run deploy:arc
```

## Demo script (for the presentation)

1. Show the dashboard, connect MetaMask on Arc testnet.
2. Deposit 20 USDC → shares minted, show it land in the vault.
3. Point out the strategy list with live APYs (Aave/Compound/Uniswap/Curve).
4. As the keeper, bump Uniswap's simulated APY up via `setApyBps` (or wait for
   a scripted APY change) to show a clear opportunity.
5. Click **Rebalance to Best APY** — funds move automatically, respecting the
   60% concentration cap.
6. Withdraw a portion to show shares → USDC redemption working end-to-end.

## Risk controls included

- Per-strategy allocation cap (`maxAllocationBps`) prevents over-concentration.
- Rebalancing only executes if the APY improvement clears a minimum threshold,
  avoiding gas-wasting churn.
- Withdrawals pull from idle balance first, then the lowest-APY strategy
  first, preserving the best-performing position as long as possible.

## Roadmap beyond the hackathon

- Replace `MockYieldStrategy` adapters with real Aave/Compound/Uniswap/Curve
  integrations as they become live on Arc.
- Pull real-time APY from an on-chain oracle instead of a keeper-set value.
- Add a management/performance fee split for the protocol treasury.
- Multi-asset support (EURC, other Arc-native stablecoins).

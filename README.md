# Monad Quick Start Guide

## Deploy and verify all markets

Configure `.env` using `.env.example`, then run:

```bash
bash script/deploy/deploy-all.sh
# Copy all printed contract addresses into .env before verification.
bash script/deploy/verify-all.sh
```

Deploy-all includes PerpDex, OneClickPerpDex, OptionsAMM with its wired
`opUSDC` token, and PredictionMarketAMM with its constructor-created `pmUSDC`
token. All use the same USDC; options and prediction have separate LP vaults.
Set `DEPLOY_MOCK_USDC=false` and `USDC_ADDRESS` to use existing six-decimal USDC.

Prediction uses the BTC, ETH, and SOL Pyth feed IDs from the canonical initial
pair configuration. `PREDICTION_FEE_BPS` defaults to 30 (0.3%) and accepts 0–500;
the fee is fixed at deployment. The configured Pyth oracle must support
`parsePriceFeedUpdatesUnique`. Create options markets and prediction rounds
separately after deployment.

Verification requires `OPUSDC_ADDRESS`, `OPTIONS_AMM_ADDRESS`, `PMUSDC_ADDRESS`,
and `PREDICTION_MARKET_AMM_ADDRESS` alongside the existing contract addresses.
It reads the prediction feed IDs and fee from the deployed contract and verifies
both new AMMs and both LP tokens using their respective constructor arguments.

## Deploy NativeStaking to Avalanche

Create a local `.env` from `.env.example` and configure either Avalanche Fuji
(`RPC_URL=https://api.avax-test.network/ext/bc/C/rpc`, `CHAIN_ID=43113`) or
Avalanche C-Chain mainnet (`RPC_URL=https://api.avax.network/ext/bc/C/rpc`,
`CHAIN_ID=43114`). Set `PRIVATE_KEY`, and optionally `BACKEND_ADDRESS` for the
account permitted to take points snapshots.

On macOS/Linux/Git Bash:

```bash
bash script/deploy/deploy-native-staking.sh
```

On Windows Command Prompt:

```bat
deploy-native-staking.bat
```

Both scripts confirm that the configured chain ID matches the RPC endpoint
before broadcasting. Pass an alternative environment file as the first argument,
for example `bash script/deploy/deploy-native-staking.sh .env.avalanche-mainnet`.

## Verify NativeStaking on Snowtrace

After deployment, add the returned address to the same environment file:

```bash
NATIVE_STAKING_ADDRESS=0x...
```

The verification scripts select the official Snowtrace API for Fuji (`43113`) or
C-Chain mainnet (`43114`) automatically. `SNOWTRACE_API_KEY` is optional; the
Snowtrace free tier accepts the placeholder used by the script.

```bash
bash verify-native-staking.sh
```

```bat
verify-native-staking.bat
```

## Initial pair configuration

Trading pairs are not stored in either DEX constructor. After deployment,
seed the canonical configuration from `script/InitialPairConfig.sol`.
Currently nine pairs are enabled: BTC, ETH, SOL, BNB, XRP, HYPE, DOGE, XAG,
and XAU (all `_USD`). Commented-out pairs are not seeded.

Set `PRIVATE_KEY`, `RPC_URL`, `CHAIN_ID`, `PERPDEX_ADDRESS`, and
`ONECLICK_PERPDEX_ADDRESS` in `.env`. Run from macOS/Linux or Git Bash on Windows:

```bash
# Simulate both contracts without sending transactions.
bash script/deploy/seed-initial-pairs.sh .env both --dry-run

# Broadcast the initial configuration to both contracts.
bash script/deploy/seed-initial-pairs.sh .env both

# Seed only one contract (only its address is required).
bash script/deploy/seed-initial-pairs.sh .env perp
bash script/deploy/seed-initial-pairs.sh .env oneclick
```

The runner loads the environment file, checks the RPC chain ID, and uses
legacy transactions for chain 56. The Foundry scripts check contract code and
ownership before configuring pairs. Each pair is a separate transaction;
seeding both contracts is not atomic.

You can also invoke the individual Foundry entry points directly:

```bash
forge script script/ConfigureInitialPairs.s.sol:ConfigurePerpDexPairs \
    --rpc-url "$RPC_URL" --broadcast

forge script script/ConfigureInitialPairs.s.sol:ConfigureOneClickPairs \
    --rpc-url "$RPC_URL" --broadcast
```

The signer in `PRIVATE_KEY` must own the target contract. Do not rerun
configuration against a contract that already contains these pairs.

## Post-deployment owner initialization

After recording `USDC_ADDRESS` and `ONECLICK_PERPDEX_ADDRESS` in the environment
file, initialize the deployment with:

```bash
bash script/deploy/initialize-deployment.sh .env
```

When `DEPLOY_MOCK_USDC=true`, this mints
`INITIAL_MOCK_USDC_MINT_AMOUNT` MockUSDC (default: 100,000,000 USDC) to the
deployed owner. It also authorizes that owner as the OneClickPerpDex backend.
Set `INITIALIZE_CONFIRM=yes` for non-interactive use.

## Options AMM vault

`OptionsAMM` is an isolated, cash-settled European-options vault. An option
buyer pays its premium in USDC and the vault takes the short/counterparty
position. LPs deposit USDC into the vault and receive transferable `opUSDC`
shares, redeemable pro rata after all open option obligations are settled.

Each option's maximum payout equals its USDC-denominated `contracts` amount;
the AMM reserves that full amount before accepting the trade and caps aggregate
reservation at 80% of vault assets. This ensures buyers are fully
collateralized. LP deposits and withdrawals lock while obligations exist,
preventing a later LP from capturing (or an early LP from stranding) the
reserve that belongs to the LPs underwriting those options. Settlement is
permissionless after expiry using a Pyth price update whose publish time is at
or after the expiry.

Deploy with `DeployOptionsAMM.s.sol`, set `USDC_ADDRESS`, `PYTH_ADDRESS`, and
`PRIVATE_KEY`, then create markets with raw Pyth-price strike units.

## LP risk circuit breaker

Both `PerpDex` and `OneClickPerpDex` reserve the maximum possible profit for
every open position (`margin * pair.maxTP`). New positions are rejected once
the aggregate reserved profit would exceed 30% of the current LP pool. At the
default 500% max TP, each 1 USDC of margin therefore reserves 5 USDC.

The first LP deposit records the initial liquidity baseline. A permissionless
keeper can call `snapshotLiquidityPool()` once every 24 hours; it compares the
current pool to the previous snapshot and records a new one. `checkDrawdown()`
is also permissionless and can be called more often by the bot. A 30% or
greater drawdown sets `tradingPaused` immediately and pauses every pair. The
owner must explicitly unpause the required pairs and call `resumeTrading()`
after resolving the incident.

The owner can use `setPairPaused(pair, true)` or `pauseAllPairs()` to freeze a
specific market or every market. A paused pair rejects opens, closes, TP/SL
triggers, and liquidations. TP/SL edits remain available, but their new levels
must be on the correct side of the current price. `PerpDex.modifyTpSl` receives
Pyth price-update data from the frontend, pays the required Pyth update fee,
and validates the edit against the updated feed price. `OneClickPerpDex`
requires its authorized backend to provide the current price as the final
argument to `modifyTpSl`.

## Direct deployment

`DeployAll`, `DeployWithppUSDC`, `DeployOneClick`, and the Kubchain testnet
script deploy `ppUSDC`, `PerpDex`, `ocUSDC`, and `OneClickPerpDex` directly.
The addresses printed by the scripts are the contract addresses to use in the
frontend. Deployments are not upgradeable; deploy a new system to change
contract code.

The main deployment scripts deliberately do not add trading pairs. Once the
contracts are deployed and the LP minters are authorized, configure pairs in a
separate transaction sequence:

```bash
forge script script/ConfigureInitialPairs.s.sol:ConfigurePerpDexPairs --rpc-url "$RPC_URL" --broadcast
forge script script/ConfigureInitialPairs.s.sol:ConfigureOneClickPairs --rpc-url "$RPC_URL" --broadcast
```

## 🚀 Deploy to Monad in 3 Steps

### **Step 1: Setup Environment**

Create `.env` file:

```bash
PRIVATE_KEY=0x...
PYTH_ADDRESS=0x...  # Get from Pyth docs for Monad
DEPLOY_MOCK_USDC=true
```

### **Step 2: Run Deployment Script**

```bash
chmod +x deploy-monad.sh
./deploy-monad.sh
```

The script will:
1. Deploy all contracts to Monad
2. Wait 30 seconds
3. Automatically verify all contracts
4. Show you the deployed addresses

### **Step 3: Done!**

Check your contracts on: https://explorer.monad.xyz

---

## Manual Deployment (Alternative)

### **Deploy**

```bash
forge script script/DeployWithppUSDC.s.sol \
    --rpc-url https://rpc.monad.xyz \
    --broadcast
```

### **Verify MockUSDC**

```bash
forge verify-contract \
    --rpc-url https://rpc.monad.xyz \
    --verifier sourcify \
    --verifier-url 'https://sourcify-api-monad.blockvision.org/' \
    --chain-id 143 \
    <MOCK_USDC_ADDRESS> \
    src/MockUSDC.sol:MockUSDC
```

### **Verify ppUSDC**

```bash
forge verify-contract \
    --rpc-url https://rpc.monad.xyz \
    --verifier sourcify \
    --verifier-url 'https://sourcify-api-monad.blockvision.org/' \
    --chain-id 143 \
    <PPUSDC_ADDRESS> \
    src/ppUSDC.sol:ppUSDC
```

### **Verify PerpDex**

```bash
forge verify-contract \
    --rpc-url https://rpc.monad.xyz \
    --verifier sourcify \
    --verifier-url 'https://sourcify-api-monad.blockvision.org/' \
    --chain-id 143 \
    --constructor-args $(cast abi-encode "constructor(address,address,address)" <USDC> <PYTH> <PPUSDC>) \
    <PERPDEX_ADDRESS> \
    src/PerpDex.sol:PerpDex
```

---

## Monad Network Info

| Parameter | Value |
|-----------|-------|
| Chain ID | 143 |
| RPC URL | https://rpc.monad.xyz |
| Explorer | https://explorer.monad.xyz |
| Verifier | Sourcify |
| Verifier URL | https://sourcify-api-monad.blockvision.org/ |

---

## Important Notes

### ⚠️ Verifier URL Must End with `/`

```bash
# ✅ Correct
--verifier-url 'https://sourcify-api-monad.blockvision.org/'

# ❌ Wrong
--verifier-url 'https://sourcify-api-monad.blockvision.org'
```

### ⚠️ Always Specify Chain ID

```bash
--chain-id 143
```

### ⚠️ Use Sourcify Verifier

```bash
--verifier sourcify
```

---

## Testing After Deployment

### **Claim MockUSDC**

```bash
cast send <MOCK_USDC_ADDRESS> \
    "mint()" \
    --rpc-url https://rpc.monad.xyz \
    --private-key $PRIVATE_KEY
```

Each wallet can claim exactly 1,000 MockUSDC once. The MockUSDC owner can
mint any amount with `ownerMint(address,uint256)` and can enable or disable
claims with `setUserMintEnabled(bool)`.

### **Approve USDC**

```bash
cast send <USDC_ADDRESS> \
    "approve(address,uint256)" \
    <PERPDEX_ADDRESS> \
    1000000000 \
    --rpc-url https://rpc.monad.xyz \
    --private-key $PRIVATE_KEY
```

### **Deposit LP**

```bash
cast send <PERPDEX_ADDRESS> \
    "depositLP(uint256)" \
    1000000000 \
    --rpc-url https://rpc.monad.xyz \
    --private-key $PRIVATE_KEY
```

---

## Files for Monad

- `deploy-monad.sh` - Automated deployment script
- `MONAD_DEPLOYMENT.md` - Complete Monad guide
- `MONAD_QUICK_START.md` - This file

---

## Summary

**Easiest Way:**
```bash
./deploy-monad.sh
```

**Manual Way:**
1. Deploy with forge script
2. Verify with sourcify verifier
3. Use Monad-specific verifier URL

**Key Difference from Other Chains:**
- Uses Sourcify instead of Etherscan
- Requires specific verifier URL with trailing `/`
- Chain ID is 143

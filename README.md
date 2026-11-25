# Monad Quick Start Guide

## EIP-7702 trading accounts

`TradingAccount7702` adds atomic approval-and-trade batches and signed sponsored
execution for the existing PerpDex, PredictionMarketAMM, and OptionAMM. Trades
and payouts remain attached to the user's existing EOA. See
[deployment, wallet integration, and tests](docs/eip7702.md).

## Markets with AtlasOracle

`PerpDexAtlas` is a separate vault based on PerpDex using AtlasOracle's signed
pull payloads. It has a dedicated deployment script and LP token. See
[Atlas deployment, feed configuration, and transaction integration](docs/perpdex-atlas.md).

`OptionAMMAtlas` and `PredictionMarketAMMAtlas` copy the existing option and
prediction vaults with Atlas pull quotes and independent LP tokens. Opening and
settlement require quotes stamped exactly at each scheduled boundary. See
[Atlas option/prediction deployment and integration](docs/atlas-markets.md).

## Deploy and verify all markets

Configure `.env` using `.env.example`, then run:

```bash
bash script/deploy/deploy-all.sh
# Copy all printed contract addresses into .env before verification.
bash script/deploy/verify-all.sh
```

If Foundry reports an unfinished previous broadcast, inspect
`broadcast/DeployAll.s.sol/<CHAIN_ID>/run-latest.json` and the deployer's on-chain
nonce before choosing a recovery mode:

```bash
# Continue the saved transactions (requires their nonces to remain valid).
bash script/deploy/deploy-all.sh --resume
# Archive the old broadcast and deploy a new set of contracts.
bash script/deploy/deploy-all.sh --start-fresh
```

Starting fresh leaves any previously deployed contracts on-chain. Addresses
printed during simulation are only predictions; after a failed broadcast, use
confirmed deployment receipts to identify actual contracts. On resume, use the
saved broadcast's confirmed addresses rather than output from a later simulation.
Read `shareToken()` on the confirmed PredictionMarketAMM to obtain its `pmUSDC`
address, which is created inside the constructor.

Deploy-all includes PerpDex, OneClickPerpDex, OptionAMM with its wired
`opUSDC` token, and PredictionMarketAMM with its constructor-created `pmUSDC`
token. All use the same USDC; option and prediction have separate LP vaults.
Set `DEPLOY_MOCK_USDC=false` and `USDC_ADDRESS` to use existing six-decimal USDC.

Prediction deploys with an empty pair registry. Seed BTC, ETH, and SOL using
the prediction seed target below. `PREDICTION_FEE_BPS` defaults to 300 (3%) and accepts 0–500;
the fee is fixed at deployment. The configured Pyth oracle must support
`parsePriceFeedUpdatesUnique`. Create option markets and prediction rounds
separately after deployment.

Verification requires `OPUSDC_ADDRESS`, `OPTION_AMM_ADDRESS`, `PMUSDC_ADDRESS`,
and `PREDICTION_MARKET_AMM_ADDRESS` alongside the existing contract addresses.
It reads the prediction fee from the deployed contract and verifies
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
The twelve enabled pairs are `BTC_USD`, `ETH_USD`, `SOL_USD`, `BNB_USD`,
`HYPE_USD`, `DOGE_USD`, `XAU_USD`, `XAG_USD`, `USD_JPY`, `EUR_USD`,
`VOO_USD`, and `QQQ_USD`. Commented-out pairs are not seeded.
BTC, ETH, and SOL allow up to 500x leverage; BNB, HYPE, DOGE, XAU, and XAG
allow 250x; FX and ETF pairs allow 100x. All pairs have a 2x minimum leverage
and 500% maximum profit on margin. Maximum position sizes are 500,000 USDC
for crypto, 20,000 USDC for metals, and 50,000 USDC for FX and ETFs.

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

## Prediction market pairs

Set `PREDICTION_MARKET_AMM_ADDRESS` in `.env` alongside `PRIVATE_KEY`, `RPC_URL`,
and `CHAIN_ID`, then seed the empty prediction registry:

```bash
bash script/deploy/seed-prediction-pairs.sh .env --dry-run
bash script/deploy/seed-prediction-pairs.sh .env
```

The `prediction` target seeds BTC, ETH, and SOL (IDs 0, 1, 2).
The `both` target still refers to the two perpetual DEX contracts.
The seed script requires an empty registry and rejects reruns. Each pair is a
separate transaction; if broadcasting stops partway through, resume the Foundry
broadcast or add the missing pairs manually rather than restarting the seed.

Pairs use a shared network-specific `PYTH_ADDRESS` oracle contract and distinct
32-byte Pyth price feed IDs. Canonical IDs in `script/InitialPairConfig.sol` were
checked against the [Pyth Hermes feed catalog](https://hermes.pyth.network/v2/price_feeds):

| Pair | Pyth price feed ID |
| --- | --- |
| BTC | `0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43` |
| ETH | `0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace` |
| SOL | `0xef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d` |

The owner can manage pairs later (export the environment variables in the shell):

```bash
cast send "$PREDICTION_MARKET_AMM_ADDRESS" 'addPair(string,bytes32)' \
    'NEW_USD' "$NEW_PYTH_FEED_ID" --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY"
cast send "$PREDICTION_MARKET_AMM_ADDRESS" 'removePair(uint256)' \
    2 --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY"
```

`pairCount()` includes removed pairs; enumerate `pairs(id)` to read
`(name, priceId, active)`. IDs are never shifted or reused. Names are case-sensitive,
and active names and feeds must be unique. Removal disables new rounds. Existing
rounds can still open, trade, resolve, and automatically pay winners using their original feed.
Re-adding a removed pair allocates a new ID.

Integrations must use `createMarket(uint256 pairId,uint64 duration,uint64 startTime,uint256 volatilityBps)`
and `Market.pairId` instead of the former asset enum. The constructor is now
`constructor(address usdc,address pyth,uint256 feeBps)`. This non-upgradeable
contract requires a new deployment to use the changed interface.

## Buy-only prediction vault

`PredictionMarketAMM` takes the counterparty side of every bet. Users pay USDC
and receive an internal, nontransferable balance representing their fixed gross
winning payout. There is no `sell`, `quoteSell`, or `claim` function. LPs receive
transferable `pmUSDC` shares and own the vault's realized profit or loss.

The win threshold remains the round's opening Pyth price: Up wins when the
closing price is greater than or equal to the opening price; Down wins otherwise.
Each purchase uses the current price to calculate odds, and its payout remains
fixed even if prices or later quotes change.

The owner sets annualized volatility when scheduling a round, between 100 and
50,000 basis points (1%-500%; `10_000` means 100%). It cannot change during the
round. The pricing model uses the following symmetric rational sigmoid:

```text
S = current price; K = round opening price
sigma = volatilityBps / 10_000
t = seconds remaining / (365 days)
z = (S/K - 1) / (sigma * sqrt(t))
pUp = (1 + z/sqrt(1 + z*z)) / 2
pDown = 1 - pUp
fee = ceil(stake * feeBps / 10_000)
winning payout = floor((stake - fee) / pChosen)
gross multiplier = winning payout / stake
```

For a 100 USDC bet at the opening price, either direction has probability 50%.
With the default 3% edge, the winning payout is **194 USDC (1.94x)**, including
the stake. An estimated 25% outcome pays about **3.88x**, and a 75% outcome
about **1.2933x**. The vault keeps losing stakes and pays winners from its assets.
The edge is an expected return only when the model probabilities match actual
outcomes. This is a heuristic odds model, not a calibrated statistical forecast;
volatility must be calibrated per asset before production use. The vault can
lose money on individual rounds or through incorrect pricing.

Trades outside 1%-95% model probability are rejected rather than having their
odds clamped. This bounds the payout to 97x at a 3% edge. Tiny trades that cannot
return more than their stake after integer rounding are also rejected. Quotes
vary with time remaining, so use `minShares` and `deadline` to protect execution.

The updated buy interface is:

```solidity
buy(uint256 marketId, bool up, uint256 assets, uint256 currentPrice,
    uint256 minShares, uint256 deadline, bytes[] priceUpdateData)
```

`assets` and `minShares` use six USDC decimals; `currentPrice` uses 18 decimals.
Fetch signed updates from Pyth Hermes and send exactly `pyth.getUpdateFee(data)`
as native currency. The contract updates Pyth, reads the market's original feed,
checks freshness (at most five seconds), confidence, exponent, and publish time,
and requires the normalized oracle price to equal `currentPrice`. Supplying an
arbitrary price cannot change executable odds. `quoteBuy(id, up, assets, price)`
returns `(winningPayout, fee)`; `winProbability(id, up, price)` returns the model
probability scaled by `1e18`. Quote prices are caller-supplied estimates; buys
verify them against Pyth. Pyth's current-price integration uses
[`updatePriceFeeds`](https://api-reference.pyth.network/price-feeds/evm/updatePriceFeeds)
followed by `getPriceNoOlderThan`; round boundaries still require the first
update at/after the boundary through `parsePriceFeedUpdatesUnique`.

Anyone can call `resolveMarket(id, boundaryUpdateData)` after expiry. A backend
keeper must submit this transaction for timely settlement; the contract does
not initiate transactions itself. Resolution verifies the boundary price and
transfers USDC directly to every winner in that same transaction, clears both
winning and losing balances, and releases the market's collateral reservation.
No user action is required to receive winnings. Resolution also works when new
trading is paused and cannot pay a market twice.

There are at most **128 distinct bettors per round**, bounding the automatic
transfer loop. Existing bettors may add bets at the limit. Integrations should
check `traderCount(id)`; capacity can fill before the trading cutoff. Resolution
gas must be budgeted for the full round and measured against the target chain
and actual USDC implementation. If USDC is paused or blocks a winner's address,
the entire settlement reverts atomically and must be retried after transfers
are permitted. Removing claims means a blocked recipient can delay all payouts
for that round; balances and reserves are preserved on failure.

The vault reserves the maximum of aggregate Up and Down payouts for each open
round and caps total reservations at 80% of USDC assets. LP deposits and
withdrawals remain locked while any exposed round is unresolved. This prevents
changes to the LP set while its profit/loss remains unknown. Vault profit/loss
is `stakes received - winning payouts`; retained fees are part of this amount,
not guaranteed realized profit. No external derivatives hedge is executed.

This changes the market struct, creation parameter, buy/quote interfaces, and
events. Redeploy the non-upgradeable contract and update integrations. Set
`PREDICTION_FEE_BPS=300` in an existing environment file to select the 3% edge;
deployment defaults do not override an explicitly configured older value.

## Post-deployment owner initialization

After recording `USDC_ADDRESS`, `ONECLICK_PERPDEX_ADDRESS`, and `BACKEND_ADDRESS` in the environment
file, initialize the deployment with:

```bash
bash script/deploy/initialize-deployment.sh .env
```

When `DEPLOY_MOCK_USDC=true`, this mints
`INITIAL_MOCK_USDC_MINT_AMOUNT` MockUSDC (default: 100,000,000 USDC) to the
deployed owner. It authorizes the nonzero `BACKEND_ADDRESS` from the environment
file as the OneClickPerpDex backend and, when `OPTION_AMM_ADDRESS` is configured,
as the OptionAMM backend. `PRIVATE_KEY` must still belong to the owner
who can perform initialization.
Set `INITIALIZE_CONFIRM=yes` for non-interactive use.

## Option AMM vault

`OptionAMM` has scheduled call/put rounds, like the prediction vault. The owner
authorizes a backend to create, open, and finalize markets. Users buy longs for
a dynamically priced USDC premium and can sell all or part back before expiry.
Backend finalization authenticates one fixed Pyth expiry price and automatically
pays remaining holders. Failed recipient transfers become funded claims so
other payouts and LP exits can proceed.

Premiums use an eight-step binomial approximation with spot, remaining time,
fixed annualized volatility, and a bid/ask fee. Each option's maximum payout is
its USDC notional; total reserves are capped at 80% of assets excluding deferred
claims. LP shares have donation protection, slippage limits, and queued exits
that stop fresh purchases until withdrawals are processed.

Deploy with `DeployOptionAMM.s.sol`, authorize `BACKEND_ADDRESS` through the
initialization script, and seed pairs with
`bash script/deploy/seed-initial-pairs.sh .env option`. Markets use 18-decimal
USD strike units. This replaces the old option ABI and requires redeployment.
See [backend lifecycle, trading interfaces, pricing limits, and LP integration](docs/option.md).

## LP risk circuit breaker

Both perpetual DEX contracts charge **3.5% of realized profit only**, after the
position's profit cap. Losing and break-even positions pay no trading fee.
The platform's 1.5% is credited to the existing owner-controlled secondary fee
vault; the remaining 2% stays in the main LP pool. Both LP pool valuations
exclude the secondary vault balance. Fee amounts round down to collateral units;
any split rounding remainder stays with LPs. `ClosePosition.closeFee` reports
the total fee, `FeeCollected` reports the platform amount, and `ProfitFeeSplit`
reports both shares. Vault PnL reflects the net change in LP capital.
For 100 USDC of gross profit, the trader receives 96.50 USDC net profit,
the platform receives 1.50 USDC, and the LP pool retains 2.00 USDC.

Both perpetual DEX contracts track OI as leveraged notional volume:
`OI = sum(open margin * leverage)`. `getOpenInterest(pair)` returns long, short,
and total OI; the existing OI fields in `pairFunding` and `pairInfo` also retain
these notional statistics. Opening a position is limited by its margin and
Available Liquidity. Notional OI is not an opening limit.

`PairInfo.liquidityRatio` is the relative weight of LP capital allocated to the
pair; `totalLiquidityRatio` is the sum of all pair weights. The current LP pool
is allocated by that weight, then divided by the pair's
`maxTP` profit multiplier and split equally between longs and shorts:
`maxMarginPerSide = poolValue * pairWeight / totalWeight / maxTPMultiplier / 2`.
For example, a pair allocated 10,000 USDC of LP capital with a 500% max TP
permits 2,000 USDC total open margin, or 1,000 USDC per direction. A 100 USDC
position uses 100 USDC of this allowance at either 2x or 500x leverage.

`getAvailableLiquidity(pair)` replaces the old `getAvailableOI()` capacity view
and returns `allocatedLiquidity`, `maxMarginPerSide`, `currentLongMargin`,
`currentShortMargin`, `availableLongLiquidity`, `availableShortLiquidity`,
`maxPositionSize`, and combined `availableLiquidity`. All values are in
collateral units. The allocation is LP
capital reserved for maximum profits; available long/short liquidity is the
additional margin that can be opened, capped by the remaining global profit
reserve. Frontends should label this capacity **Available Liquidity** and use
`getOpenInterest()` for OI statistics. `maxPositionSize` remains a separate
leveraged notional limit: a new position's size is `margin * leverage`.

`pairInfo(pair)` and `allPairs(index)` return a `PairInfo` struct with live
`availableLiquidity` and `usedLiquidity` attributes. Available liquidity is the
pair's allocated LP capital divided by its
`maxTP` profit multiplier, less used margin, respecting direction and global
profit limits. Used liquidity is the sum of open long and short margins,
independent of leverage, in collateral units (6 decimals for USDC).
`OneClickPerpDex.getAllPairs()` returns the same live structs. Frontends can
fetch both values together through `pairInfo("BTC_USD")`.
These values are calculated when read so deposits, position changes, and owner
configuration changes are reflected immediately. Frontends must update their
ABIs for the struct returns, the `availableLiquidity` and `usedLiquidity` fields, and the renamed
`liquidityRatio` and `totalLiquidityRatio` fields.

Both `PerpDex` and `OneClickPerpDex` reserve the maximum possible profit for
every open position (`margin * pair.maxTP`). New positions are rejected once
the aggregate reserved profit would exceed 100% of the current LP pool. At the
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

TP/SL levels are trigger prices for the bot and have no minimum distance from
the entry or current price when opening or editing positions. TP profit caps
and directional validation still apply. Pair `maxTP` must be positive but has
no minimum tied to maximum leverage.

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

## Verify deployed contracts

Set the deployed addresses, `RPC_URL`, and matching `CHAIN_ID` in `.env`, then run:

```bash
bash script/deploy/verify-all.sh
```

The script uses Sourcify for Robinhood Chain mainnet (`4663`) and testnet
(`46630`), with no API key required. It waits for the verification result
before reporting success and clears unrelated Etherscan keys for Sourcify calls.
Monad uses its configured Sourcify endpoint; Base and
Avalanche use Etherscan API V2 and require `ETHERSCAN_API_KEY`.

Robinhood's public Blockscout API can return a Cloudflare HTML challenge instead
of JSON. Sourcify verification works independently of that API. To verify
directly on Robinhood mainnet's Blockscout explorer, set `BLOCKSCOUT_API_KEY`
in `.env` to a PRO API key from https://dev.blockscout.com; the script then uses
the documented `https://api.blockscout.com/v2/api?chain_id=4663` gateway.
The script supplies the key in the gateway's `apikey` query parameter because
Foundry's Blockscout provider omits it from the submitted form. Keys are
URL-encoded and redacted from console output.
Sourcify verification does not confirm that Blockscout has imported the contract
or displays a verified badge. A browser import or manual verification can be
used for the explorer separately.

For `pmUSDC`, export the input locally with:

```bash
mkdir -p cache/verification
forge verify-contract <PMUSDC_ADDRESS> src/pmUSDC.sol:pmUSDC \
    --show-standard-json-input --num-of-optimizations 1 --via-ir \
    > cache/verification/pmUSDC.standard-json.json
```

Select compiler `v0.8.20+commit.a1b79de6` and contract `src/pmUSDC.sol:pmUSDC`.
Its constructor argument is the deployed `PREDICTION_MARKET_AMM_ADDRESS`,
ABI-encoded as `constructor(address)`.

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

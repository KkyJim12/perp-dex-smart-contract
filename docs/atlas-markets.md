# Atlas option and prediction markets

`OptionAMMAtlas` and `PredictionMarketAMMAtlas` are separate copies of the
current `OptionAMM` and `PredictionMarketAMM`, using the pinned Atlas pull
consumer SDK already installed for `PerpDexAtlas`. Their shared signature and
timestamp policy is in `src/oracle/AtlasMarketOracle.sol`.

The option fork keeps capped European calls/puts, the eight-step pricing model,
partial/full sales, backend authorization, LP withdrawal queues, automatic
payouts, and funded claims when a recipient cannot be paid. The prediction fork
keeps its probability model, immutable fee, buy-only fixed winning payouts,
Up-on-equality rule, mutually exclusive payout reserve, and atomic settlement.
Both retain the original trading cutoffs, participant limits, and LP protection.

Initial Atlas mappings use the user's 15 private price feeds from the supplied
My Feeds screenshot: eight crypto markets and seven stocks. Perpetuals use
`TICKER_USD` names and prediction uses `TICKER`. Missing or blank
`ATLAS_*_FEED_ID` overrides use these defaults.

BTC feed #1190 is labeled **BTC/USDT** in Atlas. The application retains its
`BTC_USD` market name and uses the signed price directly, with no USDT/USD conversion.
The private stock feeds use the user's configured sources.

| Market | Private Atlas feed | Decimal ID | bytes4 ID |
| --- | --- | --- | --- |
| BTC | BTC/USDT | 1190 | `0x000004a6` |
| ETH | ETH/USD | 1191 | `0x000004a7` |
| SOL | SOL/USD | 1193 | `0x000004a9` |
| BNB | BNB/USD | 1194 | `0x000004aa` |
| HYPE | HYPE/USD | 1195 | `0x000004ab` |
| DOGE | DOGE/USD | 1196 | `0x000004ac` |
| XRP | XRP/USD | 1197 | `0x000004ad` |
| ZEC | ZEC/USD | 1198 | `0x000004ae` |
| AAPL | AAPL/USD | 1199 | `0x000004af` |
| MSFT | MSFT/USD | 1200 | `0x000004b0` |
| AMZN | AMZN/USD | 1202 | `0x000004b2` |
| GOOGL | GOOGL/USD | 1201 | `0x000004b1` |
| META | META/USD | 1204 | `0x000004b4` |
| NVDA | NVDA/USD | 1203 | `0x000004b3` |
| TSLA | TSLA/USD | 1205 | `0x000004b5` |

Reference: [Atlas pull integration](https://docs.atlasoracle.io/developers/atlas-oracle/integrate-the-pull-mode).

## Prediction: worker-driven rounds

The owner authorizes the worker with `authorizeBackend(worker, true)`. The owner
or an authorized worker can create, open, and resolve rounds. Create with
`createMarket(pairId, duration, volatilityBps)` at any time, without a scheduled
start or UTC alignment. Durations remain 5 minutes, 15 minutes, 1 hour, or 1 day.
The round has zero start/end times until `openMarket(id)` executes. Opening sets
`startTime = block.timestamp` and `endTime = startTime + duration`, and stores the
fresh signed quote as its opening price. `MarketCreated` includes the duration;
`MarketOpened` includes the actual start/end times.

Opening has no deadline. After expiry, `resolveMarket(id)` uses a fresh signed
quote published at/after `endTime`. Both calls accept quotes at most **five
seconds old**, with no requirement to match an exact scheduled second. A worker
can retry a delayed settlement with a fresh payload; no historical payload
archive or timestamp-indexed boundary price writes are needed. Prediction uses
the same monotonic feed timestamp and same-timestamp price consistency checks
for opening, purchases, and resolution.

Settlement uses the price at execution time. A delayed worker can therefore
change the winning outcome compared with the price observed at expiry. The
backend controls opening and settlement timing and must be trusted to execute
the intended policy. The trading cutoff and expiry still apply to purchases.

## Options: exact boundary timestamps

The Pyth option contract proves the historical update is the first at/after the
scheduled boundary. Atlas authenticates a price and timestamp without that
proof, so options require signed quotes stamped exactly at `startTime` and
`endTime`. Options retain their 30-second opening window and historical expiry
settlement; boundary quotes are exempt from spot freshness checks.

Atlas must supply canonical exact-second quotes for options. Archive their
complete signed opening/expiry payloads. Without an expiry quote, settlement
and LP release can remain blocked. Options support cancellation of unexposed
scheduled/trading markets under their existing rules.

`boundaryPrices(feedId, timestamp)` commits the first accepted option boundary
value and rejects conflicting uses. The inherited getter also exists on the
prediction vault, but prediction lifecycle calls do not write it. Canonical
quote uniqueness remains a requirement of the Atlas data service.

## Price policy and units

Prediction lifecycle calls, purchases, and option sales require a signed quote:

- For the market's configured Atlas **bytes4** feed ID.
- Stamped at/before the block timestamp and at most **five seconds old**.
  Trades require a timestamp at/after the market start; prediction settlement
  requires a timestamp at/after expiry.
- With a positive price; trades require it to equal the caller's `currentPrice` argument.
- With a timestamp no older than the last successfully used spot timestamp for
  that feed in the vault. Reusing that timestamp requires the same spot price.

`ATLAS_MAX_PRICE_AGE` configures PerpDexAtlas only (range 1-5); these forks use
fixed `MAX_PRICE_AGE = 5`. Atlas supplies **18-decimal USD prices**, the
same units as the original option/prediction APIs. Unlike PerpDexAtlas, these
two contracts do not scale prices to eight decimals. Cash, notionals, and outcome
balances retain six-decimal USDC units; LP shares retain their original models.

Atlas's payload contains no Pyth confidence interval, so the Pyth-specific
confidence check is removed. The SDK authenticates prices, feed IDs, and
timestamps; feed quality and canonical boundary data must be supplied by Atlas.
Monotonic spot timestamps do not make payloads single-use or eliminate price
selection within the five-second window.

## Deployment

Constructors:

```solidity
OptionAMMAtlas(address usdc, address atlasSigner, address opUSDC)
PredictionMarketAMMAtlas(address usdc, address atlasSigner, uint256 feeBps)
```

`atlasSigner` is the trusted signing EOA, not an oracle contract address. Both
vaults use two-step ownership transfer and owner-only `setAtlasSigner(address)`.
The owner controls which signing key the vault trusts to authenticate prices.
Rotation revokes the old key immediately, including for historical payloads;
finalize rounds needing old-key quotes before rotation, or arrange for Atlas to
re-sign the canonical historical quotes under the new trusted key.

Configure an existing six-decimal `USDC_ADDRESS`, `PRIVATE_KEY`, `RPC_URL`,
`CHAIN_ID`, and `ATLAS_SIGNER` in `.env`. The scripts default to Atlas's published
reference signer `0x59eD4701224fD9e2a85Ef2946c2ab828C1dDC600` when the environment
variable is absent. Confirm the current Atlas key before deploying. Prediction
uses `PREDICTION_FEE_BPS`, default 300 (3%), with the existing 0–500 limit.

For prediction alone, the Bash runner loads the environment file, checks the RPC
chain ID, and deploys `PredictionMarketAMMAtlas` with its constructor-created
`pmUSDC` token:

```bash
bash script/deploy/deploy-prediction-atlas.sh .env --dry-run
bash script/deploy/deploy-prediction-atlas.sh .env --broadcast
# Recover an interrupted deployment after checking receipts and the deployer nonce.
bash script/deploy/deploy-prediction-atlas.sh .env --broadcast --resume
```

It defaults to simulation and accepts `--broadcast --start-fresh` to archive an
unfinished broadcast and deploy anew. Receipts are saved under
`broadcast/DeployPredictionMarketAMMAtlas.s.sol/<CHAIN_ID>/run-latest.json`.
Save the confirmed vault and `shareToken()` as `PREDICTION_MARKET_AMM_ATLAS_ADDRESS`
and `ATLAS_PMUSDC_ADDRESS`; the runner does not update the environment file.
`FOUNDRY_PROFILE=default` keeps the repository's deployment compiler settings.

The individual Solidity scripts can also be run directly:

```bash
set -a
source <(tr -d '\r' < .env)
set +a

# Confirm this matches CHAIN_ID.
cast chain-id --rpc-url "$RPC_URL"

# Simulate both deployments.
forge script script/DeployOptionAMMAtlas.s.sol --rpc-url "$RPC_URL"
forge script script/DeployPredictionMarketAMMAtlas.s.sol --rpc-url "$RPC_URL"

# Broadcast when ready.
forge script script/DeployOptionAMMAtlas.s.sol --rpc-url "$RPC_URL" --broadcast --slow
forge script script/DeployPredictionMarketAMMAtlas.s.sol --rpc-url "$RPC_URL" --broadcast --slow
```

The option script deploys a **fresh opUSDC** and one-time-wires it to its new
vault. Prediction creates its **fresh pmUSDC** in its constructor. The scripts
return `(atlasOpUSDCAddress, optionAMMAtlasAddress)` and
`(atlasPmUSDCAddress, predictionMarketAMMAtlasAddress)`. After confirmed receipts,
save them as `ATLAS_OPUSDC_ADDRESS`, `OPTION_AMM_ATLAS_ADDRESS`,
`ATLAS_PMUSDC_ADDRESS`, and `PREDICTION_MARKET_AMM_ATLAS_ADDRESS` respectively.
Use fresh LP instances; existing LP supply represents claims on existing vaults.

Neither script schedules markets, authorizes a backend, deposits liquidity, or
migrates existing positions. Register Atlas feed IDs through `addPair(name,
bytes4FeedId)` and authorize the option backend using
`authorizeBackend(backend, true)`. Authorize the prediction worker through the
same method on the prediction vault. Creation, opening, and settlement require
the prediction owner or an authorized worker. Deposit USDC liquidity before
trading. The existing Pyth seed/deployment/verification scripts target the
original contracts and cannot supply Atlas feed IDs or constructors.

The Atlas-specific seeder registers BTC, ETH, and SOL in options using the
private defaults `0x000004a6`, `0x000004a7`, and `0x000004a9`. Set
`ATLAS_BTC_FEED_ID`, `ATLAS_ETH_FEED_ID`, and `ATLAS_SOL_FEED_ID` in `.env` to
override these defaults; missing or blank values keep them. Simulate with
`bash script/deploy/seed-atlas-pairs.sh .env option` or the `prediction` target,
then add `--broadcast`. Prediction and perpetuals both register the requested
15 markets (eight crypto and seven private stock feeds), in the order listed in
`script/AtlasInitialPairConfig.sol`. All required feeds must resolve to unique,
nonzero bytes4 IDs before any pair transactions are prepared. All selected
vault registries must be empty and owned by `PRIVATE_KEY`. Inspect receipts and
nonces before resuming partial broadcasts with the same environment/target and
`--broadcast --resume`.

## Transaction integration

Use the generated ABI for each new contract. Pairs and `PairAdded` now expose
`atlasFeedId` as bytes4, and `atlasFeedIds(pairId)` replaces `priceIds(pairId)`.
The price-sensitive methods have these signatures:

```solidity
// Both vaults:
openMarket(uint256 marketId)

// OptionAMMAtlas:
buy(uint256 marketId, uint256 contracts, uint256 currentPrice,
    uint256 maxPremium, uint256 deadline)
sell(uint256 marketId, uint256 contracts, uint256 currentPrice,
     uint256 minProceeds, uint256 deadline)
finalizeMarket(uint256 marketId)

// PredictionMarketAMMAtlas:
authorizeBackend(address worker, bool authorized) // owner only
createMarket(uint256 pairId, uint64 duration, uint256 volatilityBps)
buy(uint256 marketId, bool up, uint256 assets, uint256 currentPrice,
    uint256 minShares, uint256 deadline)
resolveMarket(uint256 marketId)
```

Append signed Atlas `extraData` to the end of the individual vault call's
calldata; there is no `bytes[] data` argument or native oracle update fee. These
methods are nonpayable. The Atlas TypeScript client's `buildCalldata` can append
the payload after ABI encoding, as shown in the
[PerpDexAtlas client example](perpdex-atlas.md#transaction-api). For delegated or
batched execution, append the payload to the inner vault call. Supply a fresh
payload for trades and prediction opening/settlement. Options require archived
exact-timestamp payloads for opening/settlement. Slippage limits and deadlines
still apply. Prediction's create signature, Market tuple, and lifecycle events
have changed; update generated ABIs and deploy a new vault to use this flow.
`authorizeBackend` and `createMarket` do not require an oracle payload.

## Validation

```bash
forge test --match-contract 'AtlasMarketOracleTest|OptionAMMAtlasTest|PredictionMarketAMMAtlasTest|DeployAtlasMarketsTest' -vv
```

The tests use real ECDSA-signed Atlas-format payloads through the production SDK.
They cover malformed/unauthorized data, feed IDs, exact/historical timestamps,
spot staleness and regression, consistency, signer rotation, deployment wiring,
reserve/PnL/payout accounting, recipient failures, reentrancy, removed pairs, LP
withdrawal queues, and the EIP-170 size limit. Fuzz tests compare quote/fee math
directly against the original Pyth vaults and check capped option payoffs and
prediction payout conservation.

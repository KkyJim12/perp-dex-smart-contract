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

Reference: [Atlas pull integration](https://docs.atlasoracle.io/developers/atlas-oracle/integrate-the-pull-mode).

## Settlement rule: exact boundary timestamps

The Pyth versions prove that a historical update is the first at/after the
scheduled start or expiry. Atlas's pull SDK authenticates a price and timestamp;
it provides no equivalent first-update proof. These new contracts therefore
require a signed quote with `timestamp == startTime` when opening and
`timestamp == endTime` when settling. A quote at `endTime + 1` is rejected even
if submitted within 30 seconds of expiry.

The **30-second opening transaction window** remains: submit `openMarket`
between `startTime` and `startTime + 30`, attaching the quote stamped exactly
`startTime`. Settlement can occur any time after expiry, attaching the exact
expiry quote even if it is now historical. Historical boundary data is exempt
from the five-second spot freshness limit and the spot timestamp high-water mark.

**Atlas must supply a canonical quote for each exact scheduled second.** Confirm
this capability for the chosen feeds before scheduling funded markets. The
backend must capture and archive the complete signed opening/expiry payloads;
the documented latest-price endpoint alone does not guarantee historical quote
retrieval. Without the required expiry quote, settlement and LP release can
remain blocked. There is no arbitrary-price, nearest-timestamp, or unsigned
fallback. Option still supports cancellation of unexposed scheduled/trading
markets under its existing rules.

`boundaryPrices(feedId, timestamp)` commits the first accepted value in each
vault. Further uses of that boundary must agree and still authenticate a signed
payload. This prevents changing a committed boundary across markets in that
vault. It does not prove that Atlas issued only one price for a timestamp, or
prove which of multiple signed prices was issued first; canonical quote
uniqueness remains a requirement of the Atlas data service.

## Price policy and units

Spot purchases, and option sales, require a signed quote:

- For the market's configured Atlas **bytes4** feed ID.
- Stamped at/after the market start, at/before the block timestamp, and at most
  **five seconds old**.
- With a positive price equal to the caller's `currentPrice` argument.
- With a timestamp no older than the last successfully used spot timestamp for
  that feed in the vault. Reusing that timestamp requires the same spot price.

`ATLAS_MAX_PRICE_AGE` configures PerpDexAtlas only; these forks preserve the
original fixed `MAX_PRICE_AGE = 5`. Atlas supplies **18-decimal USD prices**, the
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
`authorizeBackend(backend, true)`. Prediction scheduling remains owner-only;
its opening and settlement remain permissionless. Deposit USDC liquidity before
trading. The existing Pyth seed/deployment/verification scripts target the
original contracts and cannot supply Atlas feed IDs or constructors.

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
payload for spot trades and the archived exact-timestamp payload for opening or
settlement. Slippage limits and deadlines still apply.

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

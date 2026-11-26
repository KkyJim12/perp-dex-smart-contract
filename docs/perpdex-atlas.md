# PerpDexAtlas

`src/PerpDexAtlas.sol` is an independent vault based on the current `PerpDex`.
It retains margin, leverage, liquidity allocation, profit caps, TP/SL, liquidation,
drawdown pauses, LP shares, and the 1.5% platform plus 2% LP winning-profit fees.
It uses the official Atlas **pull** consumer to verify signed prices supplied with
each transaction. The existing Pyth contracts and deployment scripts continue to
serve their existing deployments.

The consumer dependency is pinned to
`oracle-atlas/pull-oracle-consumer@a8f5b14036ed05f25dcebb81546bac600e138a34`.
The upstream SDK declares BUSL-1.1 in its source and package metadata.

Reference: [Atlas pull integration guide](https://docs.atlasoracle.io/developers/atlas-oracle/integrate-the-pull-mode)
and [official consumer SDK](https://github.com/oracle-atlas/pull-oracle-consumer).

## Deployment

The constructor is:

```solidity
constructor(address usdc, address ppUSDC, address atlasSigner, uint256 maxPriceAge)
```

Configure `USDC_ADDRESS`, `PRIVATE_KEY`, `RPC_URL`, and `CHAIN_ID` in `.env`.
Use six-decimal USDC collateral. `ATLAS_SIGNER` defaults to the signing key
published by Atlas at implementation time,
`0x59eD4701224fD9e2a85Ef2946c2ab828C1dDC600`.
`ATLAS_MAX_PRICE_AGE` defaults to 5 seconds and must be between 1 and 5.
The contract rejects a constructor value above five seconds. Check Atlas's current signing key
when deploying; it is a signer address, not an oracle contract address.

From Git Bash, macOS, or Linux:

```bash
set -a
source <(tr -d '\r' < .env)
set +a

# Confirm this matches CHAIN_ID before deploying.
cast chain-id --rpc-url "$RPC_URL"

# Local simulation first.
forge script script/DeployPerpDexAtlas.s.sol --rpc-url "$RPC_URL"

# Broadcast when ready.
forge script script/DeployPerpDexAtlas.s.sol --rpc-url "$RPC_URL" --broadcast --slow
```

The script deploys a **fresh ppUSDC token**, creates the Atlas vault, and authorizes
the vault to mint/burn that token. Its return values are `atlasPpUSDCAddress` and
`perpDexAtlasAddress`. After confirmation, save them as `ATLAS_PPUSDC_ADDRESS` and
`PERPDEX_ATLAS_ADDRESS`. Do not use the old vault's LP token: its supply represents
claims on that old vault. This script does not migrate positions or liquidity,
seed pairs, or deploy the other markets.

Register each pair using its Atlas-assigned **bytes4** feed ID:

To seed the eight crypto and seven private stock-feed perpetual pairs, run
`bash script/deploy/seed-atlas-pairs.sh .env perp` to simulate, then add
`--broadcast` to send. The target must be owned by `PRIVATE_KEY` and have no
registered pairs. The default `all` target also seeds the Atlas option and
prediction vaults. For partial broadcasts, use the saved plan with
`--broadcast --resume` after inspecting receipts and nonces.
Feed mappings and overrides are listed in `.env.example` and
`script/AtlasInitialPairConfig.sol`. Explicit IDs must be nonzero, unique bytes4.
Missing required feeds fail validation before any pairs are added.

```solidity
dex.addPair("BTC_USD", atlasBtcFeedId, 20, 50_000e6, 2, 100, 5e18);
```

Obtain the feed IDs and service credentials from Atlas onboarding. Pyth's bytes32
IDs and the repository's Pyth pair seeder cannot be used here. Zero feed IDs are
rejected. Once pairs are configured, approve and deposit USDC through `depositLP`
before opening positions.

## Transaction API

Encode these functions with the generated `PerpDexAtlas` ABI and append Atlas's
signed `extraData` to the **end of that individual contract call's calldata**:

```solidity
openPosition(string pair, bool isLong, uint256 margin, uint256 leverage,
             uint256 takeProfit, uint256 stopLoss)
modifyTpSl(bytes32 positionId, uint256 newTP, uint256 newSL)
closePosition(bytes32 positionId)
triggerTpSl(address user, bytes32 positionId)
liquidate(address user, bytes32 positionId)
closeAllPositions()
```

These functions are nonpayable and have no `bytes[] priceUpdateData` argument.
Atlas payloads are not Pyth updates. Send zero native currency. USDC approval,
margin, LP amounts, and share amounts retain their existing units. Pair and
position structs and events use `atlasFeedId` (`bytes4`) instead of `pythTokenId`.

Atlas prices arrive at 18 decimals. The contract divides them by `1e10`, rounding
down, so entry/close/TP/SL/liquidation prices keep the existing **eight-decimal**
scale. For example, `$50,000` is `50_000e8` in TP/SL arguments and position views.

The official client can fetch the signed data and assemble the call:

```ts
import { PullOracleConsumerClient } from "@atlas-oracle/pull-oracle-consumer-sdk";

const client = new PullOracleConsumerClient({
  http: { apiKey: process.env.ATLAS_API_KEY! },
  validate: true,
  maxDelay: 5,           // Match the deployed vault's maxPriceAge().
  maxFutureDrift: 0,
  maxPackageCount: 255,
});

// Use the service's feed identifier for the pair's configured bytes4 ID.
const priceData = await client.fetchPrices([atlasBtcServiceFeedId]);
const data = client.buildCalldata({
  abi: perpDexAtlasAbi,
  functionName: "openPosition",
  args: ["BTC_USD", true, 100_000_000n, 10n, 55_000n * 10n ** 8n, 0n],
  extraData: priceData.extraData,
});
await signer.sendTransaction({ to: perpDexAtlasAddress, data, value: 0n });
```

For a delegated account or batch executor, append the payload to the **inner
PerpDexAtlas call**, not the outer executor call. TP/SL and liquidation bots must
also fetch signed data. Emergency `closeAllPositions` requires one payload
containing every feed used by the non-paused open positions it will close; a
missing, invalid, or stale required feed reverts the entire close operation.
Large position sets may exceed transaction gas or the SDK's 255-feed limit; bots
can close positions individually instead.

## Verification policy

The SDK verifies the payload's signature, marker, package count, and requested
feed. The vault accepts only its configured signer and rejects zero prices,
prices rounding to zero, zero/future timestamps, and prices older than
`maxPriceAge`. A successful operation updates `lastPriceTimestamp(feedId)` and
later operations cannot use older timestamps for that feed. The same timestamp
may be reused; this is monotonic validation, not single-use payload protection.
Atlas signatures authenticate the feed data, not the user's trade parameters.
As documented by Atlas, valid signed prices can be replayed within the freshness
window. This contract does not impose per-user cooldowns or require a strictly
newer price to close a position; choose the configured age accordingly.

The owner can rotate the trusted key using `setAtlasSigner(address)` after an
official Atlas signing-key rotation. The constructor fixes the maximum age.
There is no cached-price or owner-supplied unsigned-price fallback.

The Atlas fork also tracks traders when they open their first position, so
emergency closure includes traders who have not registered a username. Position
IDs include the user's position index to distinguish multiple opens in one block.

## Tests

```bash
forge test --match-contract 'PerpDexAtlasTest|DeployPerpDexAtlasTest' -vv
```

Tests create genuine ECDSA-signed Atlas-format payloads and exercise the production
consumer SDK. They cover signature and feed validation, timestamps, precision,
signer rotation, fee/PnL accounting, TP/SL, liquidation, atomic multi-feed emergency
closure, and the EIP-170 runtime bytecode limit.

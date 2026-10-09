# Shared options formulas for backend and frontend

The source of truth is the current `src/OptionsAMM.sol`, particularly
`optionValue`, `quoteBuy`, `quoteSell`, and `_payoff`. The dependency-free
[JavaScript module](../sdk/options-math.mjs) reproduces its integer math and
has [TypeScript declarations](../sdk/options-math.d.mts). It works in Node and
browser bundles. Both applications should import this same module.

This document describes the implemented eight-step model. It does not replace
that model with Black-Scholes or the prediction contract's probability formula.

## Inputs and units

| Symbol / field | Meaning | On-chain encoding |
| --- | --- | --- |
| S / `currentPrice` | Current underlying USD price | 18 decimals: $100 = `100n * 10n**18n` |
| K / `strikePrice` | Market's opened strike | Same 18 decimals; read `getMarket`, especially for ATM strike |
| N / `contracts` | USDC notional, not number of underlying units | 6 decimals: 1,000 USDC = `1000n * 10n**6n` |
| sigma / `volatilityBps` | Fixed annualized volatility | 10,000 bps = 100% = sigma 1.0 |
| f / `feeBps` | Fee on model premium | 300 bps = 3%; charged on premium, not notional |
| T | Seconds from quote block to expiry | `endTime - block.timestamp`, never milliseconds |
| W | Fixed-point scale for prices and unit values | `10n**18n` |

All arithmetic inputs in the module are `bigint`. Use decimal strings for UI
input, `parseUnits`, and `formatUnits`. `expo` is an integer JavaScript number;
market status can be the ABI's number or bigint enum value (Trading = 1).
Serialize bigint values as decimal strings across JSON and restore them with
`BigInt`. Do not convert large prices or amounts through `Number` or `parseFloat`.

## 1. Expiry payoff

In ordinary, unscaled quantities:

```text
call payout = N * min(max(S_expiry - K, 0), K) / K
put payout  = N * min(max(K - S_expiry, 0), K) / K
```

The contract floors the final payout to raw USDC units. Maximum payout is N.
For positive underlying prices, the put's intrinsic is already below K; the
call cap changes its economics. A capped call is equivalent to a long call at
K and a short call at 2K, scaled by N/K. This follows directly by subtracting
the two intrinsic payoff functions.

For a 1,000 USDC call at $100 strike: $100 expiry pays zero, $150 pays 500 USDC,
and $200 or higher pays 1,000 USDC. The original premium is not refunded or added
to these amounts. There is no additional settlement fee.

Use the market's authenticated `closingPrice`, not the current spot, for actual
expiry P/L. Finalization uses the first Pyth update at/after expiry; see
[Pyth unique boundary parsing](https://api-reference.pyth.network/price-feeds/evm/parsePriceFeedUpdatesUnique).

## 2. Model value before expiry

Conceptually, with n = 8, zero interest, and a 365-day year:

```text
dt = T / (31,536,000 * 8)
u  = 1 + sigma * sqrt(dt)
d  = 1 / u
p  = (1 - d) / (u - d) = 1 / (u + 1)
S_i = S * d^8 * u^(2*i), i = 0..8
V_i = capped terminal payoff per 1 USDC notional
V_j(previous step) = p*V_(j+1) + (1-p)*V_j
```

Reduce the nine terminal values backward through eight steps. The last value
is the model premium per USDC of notional. It is a monetary ratio, **not a
probability of winning**. For example, a value of `0.001192` means approximately
0.001192 USDC of premium per USDC of notional; it does not mean a 0.1192% win chance.

The exact on-chain fixed-point calculations are:

```text
horizon = floor_sqrt(floor(T * W^2 / (YEAR * 8)))
up      = W + floor(volatilityBps * 10^14 * horizon / W)
p       = floor(W^2 / (up + W))
up2     = floor(up * up / W)
```

Start at S, apply `floor(spot * W / up)` eight separate times, then advance
each terminal spot using `floor(spot * up2 / W)`. Terminal intrinsic and every
backward step also floor. Do not replace these loops with floating-point powers,
or combine their divisions: doing so changes raw quotes. The module follows
the contract's exact sequence and integer square root.

## 3. Buy and sell quotes

Let v be the W-scaled unit model value:

```text
buyFair = ceil(N * v / W)
buyFee  = ceil(buyFair * feeBps / 10,000)
premium = buyFair + buyFee

sellFair = floor(N * v / W)
sellFee  = ceil(sellFair * feeBps / 10,000)
proceeds = sellFair - sellFee
```

`premium` already includes the USDC fee: approve and charge it once.
`proceeds` already deducts the USDC fee: do not subtract it a second time.
The separate Pyth update fee and transaction gas use native currency.

With unchanged price, time, and market parameters, buying and immediately selling
loses the bid/ask spread plus rounding. A later sale uses the new model value
and is not a refund or percentage of the original purchase premium.

Minimum purchased/sold notional is 1 USDC. Zero model value rejects buys but
allows closing an existing position for zero proceeds. A partial sale must
leave zero or at least 1 USDC of notional.

## Worked quotes

These exact contract-matching quotes assume a call, $100 strike, 1,000 USDC
notional, 300 seconds remaining, 100% annualized volatility, and 3% fees:

| Current spot | Buy premium (USDC, fee included) | Sell proceeds (USDC, fee deducted) | Payout if expiry occurs at this price |
| --- | --- | --- | --- |
| $99 | Purchase rejected: model value zero | 0 | 0 |
| $100 | 1.227810 | 1.156285 | 0 |
| $101 | 10.300000 | 9.699999 | 10 |
| $150 | 515.000000 | 484.999999 | 500 |
| $200 | 1,027.544384 | 967.687427 | 1,000 |

At $100, buying costs 1.227810 USDC. Immediate resale returns 1.156285 USDC,
an economic loss of 0.071525 USDC before native fees. If held to a $101 expiry,
the payout is 10 USDC and net P/L is 8.772190 USDC before native fees.

The $200 quote illustrates a consequence of applying a fee above the model
value: premium can exceed the maximum payout. The contract permits this.
A frontend should clearly show `maxNetProfit = N - premium` and avoid presenting
such a purchase as potentially profitable when that value is zero or negative.

## 4. P/L and break-even display

For a single purchase held until expiry:

```text
expiry P/L = payout - original premium (including buy fee)
maximum net profit = N - original premium
maximum economic loss = original premium
call break-even = K * (1 + premium / N)
put break-even  = K * (1 - premium / N)
```

For exact raw-unit thresholds, use `movement = ceil(K * premium / N)`:
call break-even is `K + movement`, put break-even is `K - movement`. Break-even
is unreachable when premium > N. For puts, premium = N would require a zero
expiry price, which the oracle validation rejects. Thresholds above the
contract's maximum normalized price are also unreachable.

The module's `breakEvenPrice` returns the exact threshold, or null when
unreachable. Actual feed prices have their own tick size; round a displayed
call threshold upward and a put threshold downward to that tick when determining
the first realizable feed observation. This is an expiry break-even, not a
guarantee about the premium received on an earlier sale.

To display a position before expiry, use its **sell proceeds**, not its buy quote:

```text
unrealized P/L = current net sell proceeds - remaining cost basis
```

Positions aggregate repeated buys in one balance. An indexer must retain cost
basis from Bought/Sold events. For average-cost tracking, a buy adds its actual
premium to the cost basis. Selling x of an existing Q notional removes
`floor(costBasis * x / Q)` from cost basis, and realizes
`actualSaleProceeds - removedCost`. A full close removes the entire remaining
cost basis. Finalization settles whatever notional remains. PayoutDeferred is
a funded receivable; keep it distinct from an actual token receipt in cash-flow
displays. Profit can be negative, so use signed bigint values for P/L.

## Shared usage

```javascript
import {
  quoteBuy, quoteSell, settlementPayout, breakEvenPrice,
  normalizePythPrice, parseUnits, formatUnits,
} from './sdk/options-math.mjs';

// Prefer one block snapshot for getMarket, tradingPaused, and timestamp.
const market = {
  status: 1, endTime: 600n, strikePrice: parseUnits('100', 18),
  volatilityBps: 10_000n, feeBps: 300n, isCall: true,
};
const blockTimestamp = 300n;
const notional = parseUnits('1000', 6);
const spot = normalizePythPrice({ price: 10_000_000_000n, conf: 0n, expo: -8 });
const buy = quoteBuy(market, notional, spot, blockTimestamp);
const sell = quoteSell(market, notional, spot, blockTimestamp);

console.log(formatUnits(buy.premium, 6));   // "1.22781"
console.log(formatUnits(sell.proceeds, 6)); // "1.156285"
console.log(formatUnits(breakEvenPrice(true, market.strikePrice, notional, buy.premium), 18));
// "100.122781"
```

Read the real market from getMarket; the values above are a reproducible example.
Pass tradingPaused as the final quote argument when true. JS estimates require
no wallet or native fee, but they do not authenticate signed oracle updates.

The frontend can update previews locally between block reads. Before submitting,
refresh the market/block/oracle snapshot, compare with the contract quote, and
simulate buy/sell with the intended Pyth payload and fee. The transaction's
actual block timestamp can differ, so preserve slippage limits and a short
deadline. A buy uses maxPremium; a sell uses minProceeds. Spot-price equality is
exact and independent of those cash slippage limits.

Quotes do not check LP availability, pending withdrawals, participant capacity,
or a seller's balance. Execution does. Therefore a valid local or on-chain
quote alone does not guarantee a successful transaction.

Pyth price normalization uses `rawPrice * 10^(18 + expo)` for exponents -18 to 0
and validates confidence <= 1% of raw price. Execution additionally requires
the signed price to be at most five seconds old and not from the future.
[Pyth current-price API](https://api-reference.pyth.network/price-feeds/evm/getPriceNoOlderThan).

## Model limitations

This is an eight-step, zero-interest, discrete tree with `u = 1 + sigma*sqrt(dt)`.
It is not the usual exponential up factor of a full CRR implementation and is
not a Black-Scholes price. Low node counts and finite support can create zero
quotes or visible kinks, especially for short rounds and options far from strike.

Call value increases with spot and put value decreases with spot at a fixed
time/model. Do not assume more time or volatility always increases a capped
call's price: its upside is limited, so an already highly in-the-money option
can lose expected payout when its downside dispersion increases. Model-implied
monotonicity in time/volatility also need not be smooth in this discrete tree.
The backend sets fixed volatility and fees when scheduling; calibration errors
and volatility changes during the round remain LP risks.

The module must change together with any future contract pricing change.
Using a different backend model while leaving the contract unchanged will
produce different executable quotes.

## Verification

```bash
node --test sdk/options-math.test.mjs
node sdk/options-example.mjs
# Generate artifacts first when running from a fresh clone:
forge build
node sdk/options-math.parity.mjs
```

The parity test launches and terminates its own local Anvil instance. It compares
753 unit values and 4,518 buy/sell outcomes against the actual compiled contract
across calls/puts, all five supported durations, volatility/fee bounds, near-expiry
times, tiny rounding differences, automatic opening strike, and maximum price.
Amounts match exactly. Set FOUNDRY_BIN if forge/cast/anvil are installed outside
the default ~/.foundry/bin directory. This checks agreement with the implemented
model; it does not establish that its prices match an external options market.

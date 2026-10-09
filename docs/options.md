# Options AMM integration

The vault sells capped, cash-settled European calls and puts. Users pay a USDC
premium to buy a long and may sell all or part of that long back before the
trading cutoff. Users cannot write naked short options. The vault is the
counterparty; opUSDC holders bear its realized profit and loss.

This implementation changes the old options ABI and requires a new deployment
of both OptionsAMM and its one-time-wired opUSDC token. Existing deployed
contracts cannot be upgraded or pointed at the new vault.

## Deployment and backend setup

The constructor remains `constructor(address usdc,address pyth,address opUSDC)`.
All three addresses must have code; USDC and opUSDC must have six decimals.
DeployOptionsAMM and DeployAll wire opUSDC after creating the vault.

Record the new addresses in the environment file. Configure `BACKEND_ADDRESS`
and run the existing initialization script, which now authorizes that backend
on OptionsAMM when `OPTIONS_AMM_ADDRESS` is configured. Alternatively, the owner
can call `authorizeBackend(backend,true)` directly. Authorization can be revoked.
The owner remains able to operate rounds if the backend needs recovery.

Seed BTC, ETH, and SOL using the new options target:

```bash
bash script/deploy/seed-initial-pairs.sh .env options --dry-run
bash script/deploy/seed-initial-pairs.sh .env options
```

Pair IDs are permanent. The owner adds or removes pairs. Removing a pair stops
new markets but preserves the feed and lifecycle of existing markets.

## Backend lifecycle

```solidity
createMarket(uint256 pairId, uint64 duration, uint64 startTime,
    uint256 strikePrice, uint256 volatilityBps, uint256 feeBps, bool isCall)
openMarket(uint256 marketId, bytes[] boundaryUpdateData) payable
finalizeMarket(uint256 marketId, bytes[] boundaryUpdateData) payable
```

Creation, opening, cancellation, and finalization require an authorized backend
or the owner. Trading does not require backend authorization. Status moves from
Scheduled to Trading to Finalized. A market with no exposure may be cancelled.

Durations match prediction rounds: 300, 900, 3,600, or 86,400 seconds. Start time
must be in the future and aligned to the duration (`startTime % duration == 0`).
Strike uses 18-decimal USD units (`100e18` means $100). Zero strike selects the
authenticated opening price when the market opens. Volatility is annualized,
100-50,000 bps (1%-500%). Fee is 0-500 bps (0%-5%) of model premium, not notional.
Strike, volatility, and fee are immutable after scheduling. Calls and puts are
separate markets. Duplicate pair/duration/start/strike/direction schedules revert.

The backend opens within 30 seconds of start. Both opening and finalization
authenticate the first Pyth update at/after the boundary within a 30-second
oracle window using
[parsePriceFeedUpdatesUnique](https://api-reference.pyth.network/price-feeds/evm/parsePriceFeedUpdatesUnique).
The configured Pyth deployment must support this method. Archive the signed
boundary payloads for retry/recovery. Finalization can occur later using that
historical payload; a newer shared Pyth cache cannot change the expiry price.

Finalization automatically transfers every remaining holder's intrinsic payout
to that holder in the same transaction and clears balances/reserves. It works
while trading is paused and cannot pay a round twice. There are at most 128
distinct holders per market; repeat buys and selling/rebuying reuse one slot.
Measure full-capacity finalization against the target chain and actual USDC.

If an individual token transfer reverts or returns false, that transfer is
rolled back and recorded in `claimable(holder)` instead. Other holders are
still paid. The failed payment remains fully funded and excluded from LP NAV;
the holder can call `claim()` once USDC permits transfers. Automatic transfers
have a 100,000 gas allowance, so unusual token implementations may also defer.
Ordinary successful finalization requires no user claim transaction.

## Quotes, buys, and sales

```solidity
quoteBuy(uint256 marketId,uint256 contracts,uint256 currentPrice)
    returns (uint256 premium,uint256 fee)
quoteSell(uint256 marketId,uint256 contracts,uint256 currentPrice)
    returns (uint256 proceeds,uint256 fee)
buy(uint256 marketId,uint256 contracts,uint256 currentPrice,
    uint256 maxPremium,uint256 deadline,bytes[] priceUpdateData) payable
sell(uint256 marketId,uint256 contracts,uint256 currentPrice,
    uint256 minProceeds,uint256 deadline,bytes[] priceUpdateData) payable
```

`contracts` is USDC notional at six decimals, not a count of underlying units.
Minimum notional is 1 USDC. Prices use 18 decimals. Balances are aggregated in
`optionBalance(marketId,holder)`. There are no per-purchase position IDs.

For buys, approve the vault for the quoted premium. For sales, no USDC approval
is needed: the contract checks the caller's option balance. Partial sales must
leave either zero notional or at least 1 USDC. A worthless position may be closed
for zero proceeds if `minProceeds` is zero.

Quotes use caller-supplied spot estimates. Execution updates Pyth and requires
the normalized authenticated price to equal `currentPrice`. Updates must be at
most five seconds old, not from the future, and have confidence no greater than
1% of price. Positive prices with exponents -18 through 0 are normalized;
prices above `1e30` normalized units are rejected. Send exactly
`pyth.getUpdateFee(data)` as native currency. Preserve `maxPremium`/`minProceeds`
and the trade deadline in integrations. Trading stops five seconds before expiry.

## Premium model and payoff

For exact shared backend/frontend math, worked quotes, P/L and break-even,
see [options pricing formulas](options-pricing.md) and [the shared JavaScript module](../sdk/options-math.mjs).

Premiums use an eight-step risk-neutral binomial approximation, zero interest,
and the market's fixed volatility. With `dt = timeRemaining/(365 days * 8)`,
the up factor is `u = 1 + sigma*sqrt(dt)`, the down factor is `d = 1/u`, and
the up probability is `p = 1/(u+1)`. The contract values the actual capped payoff
at terminal nodes and discounts backward with zero interest. Buy quotes round
up and add a fee; sale quotes round down and deduct a fee. Fees remain in the
vault. Quote amounts are not refunds of the original premium.

For notional N, expiry price S, and strike K:

```text
call payout = N * min(max(S-K, 0), K) / K
put payout  = N * min(max(K-S, 0), K) / K
```

Payoffs round down. Calls reach their notional cap at S >= 2K. A 1,000 USDC call
with a $100 strike pays 500 USDC at $150 and 1,000 USDC at $200 or higher.

The model is an approximation rather than a calibrated Black-Scholes engine.
An eight-step tree has finite terminal support; sufficiently far out-of-the-money
options can quote zero and cannot be bought. Market volatility and spreads must
be calibrated to each asset before production trading. The collateral cap
ensures payout funding, not an expected LP profit or an accurate market price.

## LP deposits and exits

```solidity
deposit(uint256 assets,uint256 minShares)
withdraw(uint256 shares,uint256 minAssets)
requestWithdrawal(uint256 shares)
cancelWithdrawal()
executeWithdrawal(address lp)
```

Each open notional reserves its entire maximum payout, with reservations capped
at 80% of assets excluding deferred claims. Selling releases the corresponding
reserve. `vaultValue` subtracts both reserves and funded claims, so it is
conservative while options are open and exact net equity after exposure closes.

Deposits and direct withdrawals wait for all exposed markets to close.
`previewDeposit` and `previewRedeem` use one virtual asset and one million
virtual shares to protect against donation/rounding attacks. opUSDC still has
six decimals; the initial raw share count is one million times the raw deposited
asset count. Use previews rather than assuming shares redeem 1:1 with USDC.

An LP may approve opUSDC to the vault and escrow shares through requestWithdrawal
while obligations remain open. A request must represent at least 1 USDC of
current conservative equity, preventing negligible share dust from halting buys.
Any queued request stops new buys globally,
allowing existing positions to sell or reach expiry without admitting fresh
exposure. Once exposure is zero, anyone can execute the request; proceeds always
go to that LP. Requested shares continue bearing the existing rounds' P/L and
execute at eventual NAV without a minimum-assets limit. LPs can cancel requests
and recover their shares before execution. A blocked LP payment becomes a
funded claim so its processed request does not keep buys paused. Deferred claims
remain excluded from deposits, withdrawals, and purchase utilization limits.

Backend downtime still requires owner recovery to finalize expired exposure.
The contract does not initiate transactions by itself.

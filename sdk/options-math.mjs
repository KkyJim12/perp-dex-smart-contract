// SPDX-License-Identifier: MIT
// Dependency-free math for the current src/OptionsAMM.sol. All monetary math uses bigint.
export const WAD = 10n ** 18n;
export const USDC_UNIT = 10n ** 6n;
export const BPS = 10_000n;
export const YEAR = 31_536_000n;
export const PRICING_STEPS = 8;
export const TRADING_CUTOFF = 5n;
export const MAX_PRICE = 10n ** 30n;
export const UINT256_MAX = (1n << 256n) - 1n;

function uint(value, label) {
  if (typeof value !== 'bigint' || value < 0n || value > UINT256_MAX) {
    throw new RangeError(`${label} must be a uint256 bigint`);
  }
  return value;
}

function checked(value) {
  return uint(value, 'Arithmetic result');
}

export function sqrtFloor(value) {
  uint(value, 'Square-root input');
  if (value < 2n) return value;
  let x = 1n << BigInt(Math.ceil(value.toString(2).length / 2));
  let next = (x + value / x) / 2n;
  while (next < x) {
    x = next;
    next = (x + value / x) / 2n;
  }
  return x;
}

function mulDiv(x, y, denominator, roundUp = false) {
  const product = x * y;
  const quotient = product / denominator;
  return checked(quotient + (roundUp && product % denominator !== 0n ? 1n : 0n));
}

function validatePrice(price) {
  uint(price, 'Price');
  if (price === 0n || price > MAX_PRICE) throw new RangeError('Invalid price');
}

function validateMarket(market, now, tradingPaused) {
  uint(now, 'Block timestamp');
  uint(market.endTime, 'Market end time');
  if (tradingPaused) throw new Error('Trading paused');
  if ((market.status !== 1 && market.status !== 1n) || now + TRADING_CUTOFF >= market.endTime) {
    throw new Error('Market closed');
  }
  validatePrice(market.strikePrice);
  uint(market.volatilityBps, 'Volatility');
  uint(market.feeBps, 'Fee');
  if (typeof market.isCall !== 'boolean') throw new TypeError('isCall must be boolean');
  if (market.volatilityBps < 100n || market.volatilityBps > 50_000n) {
    throw new RangeError('Invalid volatility');
  }
  if (market.feeBps > 500n) throw new RangeError('Fee exceeds 5%');
}

function payoffUnchecked(isCall, strikePrice, price, notional) {
  const difference = isCall ? price - strikePrice : strikePrice - price;
  const intrinsic = difference < 0n ? 0n : difference > strikePrice ? strikePrice : difference;
  return mulDiv(notional, intrinsic, strikePrice);
}

/** Model premium per USDC of notional, before spread; return value is scaled by WAD. */
export function optionValue(market, spotPrice, now, tradingPaused = false) {
  validateMarket(market, now, tradingPaused);
  validatePrice(spotPrice);
  const remaining = market.endTime - now;
  const horizon = sqrtFloor(mulDiv(remaining, WAD * WAD, YEAR * BigInt(PRICING_STEPS)));
  const up = WAD + mulDiv(market.volatilityBps * 10n ** 14n, horizon, WAD);
  const probability = WAD * WAD / (up + WAD);
  const upSquared = mulDiv(up, up, WAD);
  let nodeSpot = spotPrice;
  const values = [];

  // Preserve each division: a single power expression has different rounding.
  for (let i = 0; i < PRICING_STEPS; ++i) nodeSpot = mulDiv(nodeSpot, WAD, up);
  for (let i = 0; i <= PRICING_STEPS; ++i) {
    values.push(payoffUnchecked(market.isCall, market.strikePrice, nodeSpot, WAD));
    nodeSpot = mulDiv(nodeSpot, upSquared, WAD);
  }
  for (let step = PRICING_STEPS; step > 0; --step) {
    for (let j = 0; j < step; ++j) {
      values[j] = (values[j + 1] * probability + values[j] * (WAD - probability)) / WAD;
    }
  }
  return values[0];
}

/** Total USDC required, including the vault's fee. */
export function quoteBuy(market, notional, spotPrice, now, tradingPaused = false) {
  uint(notional, 'Notional');
  if (notional < USDC_UNIT) throw new RangeError('Notional too small');
  const unitValue = optionValue(market, spotPrice, now, tradingPaused);
  const fair = mulDiv(notional, unitValue, WAD, true);
  if (fair === 0n) throw new Error('Premium too small');
  const fee = mulDiv(fair, market.feeBps, BPS, true);
  return { unitValue, fair, fee, premium: checked(fair + fee) };
}

/** USDC returned for closing this much purchased notional, after the vault's fee. */
export function quoteSell(market, notional, spotPrice, now, tradingPaused = false) {
  uint(notional, 'Notional');
  if (notional < USDC_UNIT) throw new RangeError('Notional too small');
  const unitValue = optionValue(market, spotPrice, now, tradingPaused);
  const fair = mulDiv(notional, unitValue, WAD);
  const fee = mulDiv(fair, market.feeBps, BPS, true);
  return { unitValue, fair, fee, proceeds: fair - fee };
}

/** Intrinsic expiry payout, without premium refunds or an additional settlement fee. */
export function settlementPayout(isCall, strikePrice, closingPrice, notional) {
  if (typeof isCall !== 'boolean') throw new TypeError('isCall must be boolean');
  validatePrice(strikePrice);
  validatePrice(closingPrice);
  uint(notional, 'Notional');
  return payoffUnchecked(isCall, strikePrice, closingPrice, notional);
}

/** Exact expiry break-even threshold, including paid buy fees. Null means unreachable. */
export function breakEvenPrice(isCall, strikePrice, notional, premiumPaid) {
  if (typeof isCall !== 'boolean') throw new TypeError('isCall must be boolean');
  validatePrice(strikePrice);
  uint(notional, 'Notional');
  uint(premiumPaid, 'Premium paid');
  if (notional === 0n) throw new RangeError('Zero notional');
  if (premiumPaid > notional || (!isCall && premiumPaid === notional)) return null;
  const movement = mulDiv(strikePrice, premiumPaid, notional, true);
  const threshold = isCall ? strikePrice + movement : strikePrice - movement;
  return threshold > MAX_PRICE ? null : threshold;
}

/** Normalize Pyth price/confidence; signed timestamp verification remains an on-chain check. */
export function normalizePythPrice({ price, conf, expo }) {
  if (typeof price !== 'bigint' || price <= 0n || price > (1n << 63n) - 1n) {
    throw new RangeError('Invalid Pyth price');
  }
  if (typeof conf !== 'bigint' || conf < 0n || conf > (1n << 64n) - 1n) {
    throw new RangeError('Invalid Pyth confidence');
  }
  if (typeof expo !== 'number' || !Number.isInteger(expo) || expo < -18 || expo > 0) {
    throw new RangeError('Invalid price exponent');
  }
  if (conf * BPS > price * 100n) throw new Error('Uncertain price');
  const normalized = price * 10n ** BigInt(18 + expo);
  validatePrice(normalized);
  return normalized;
}

/** Decimal-string input; never route user input through Number/parseFloat first. */
export function parseUnits(value, decimals) {
  if (typeof value !== 'string' || !Number.isInteger(decimals) || decimals < 0 || decimals > 36) {
    throw new TypeError('Use a decimal string and an integer decimals count from 0 to 36');
  }
  if (!/^\d+(\.\d+)?$/.test(value)) throw new Error('Invalid decimal string');
  const [whole, fraction = ''] = value.split('.');
  if (fraction.length > decimals) throw new RangeError('Too many decimal places');
  return checked(BigInt(whole) * 10n ** BigInt(decimals) + BigInt(fraction.padEnd(decimals, '0') || '0'));
}

/** Exact decimal-string output; supports signed P/L and trims trailing fractional zeros. */
export function formatUnits(value, decimals) {
  if (typeof value !== 'bigint' || !Number.isInteger(decimals) || decimals < 0 || decimals > 36) {
    throw new TypeError('Use a bigint and an integer decimals count from 0 to 36');
  }
  const sign = value < 0n ? '-' : '';
  const magnitude = value < 0n ? -value : value;
  const scale = 10n ** BigInt(decimals);
  const fraction = (magnitude % scale).toString().padStart(decimals, '0').replace(/0+$/, '');
  return sign + (magnitude / scale).toString() + (fraction ? '.' + fraction : '');
}

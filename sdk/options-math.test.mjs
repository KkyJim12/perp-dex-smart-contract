import test from 'node:test';
import assert from 'node:assert/strict';
import { WAD, UINT256_MAX, optionValue, quoteBuy, quoteSell, settlementPayout,
  normalizePythPrice, parseUnits, formatUnits, sqrtFloor, breakEvenPrice } from './options-math.mjs';

const market = { status: 1, endTime: 600n, strikePrice: 100n * WAD,
  volatilityBps: 10_000n, feeBps: 300n, isCall: true };

test('expiry intrinsic, cap, direction and premium treatment', () => {
  assert.equal(settlementPayout(true, 100n * WAD, 150n * WAD, 1_000_000_000n), 500_000_000n);
  assert.equal(settlementPayout(true, 100n * WAD, 300n * WAD, 1_000_000_000n), 1_000_000_000n);
  assert.equal(settlementPayout(false, 100n * WAD, 50n * WAD, 1_000_000_000n), 500_000_000n);
  assert.equal(settlementPayout(false, 100n * WAD, 150n * WAD, 1_000_000_000n), 0n);
  assert.equal(settlementPayout(true, 3n * WAD, 4n * WAD, 1_000_000n), 333_333n);
});

test('integer square root is floor-valued at small and uint256 boundaries', () => {
  for (const x of [0n, 1n, 2n, 3n, 4n, 15n, 16n, 17n, UINT256_MAX]) {
    const root = sqrtFloor(x);
    assert(root * root <= x);
    assert((root + 1n) * (root + 1n) > x);
  }
});

test('decimal input and display preserve precision and signed P/L', () => {
  assert.equal(parseUnits('1000.000001', 6), 1_000_000_001n);
  assert.equal(parseUnits('100.123456789123456789', 18), 100_123_456_789_123_456_789n);
  assert.equal(formatUnits(-1_234_567n, 6), '-1.234567');
  assert.equal(formatUnits(0n, 18), '0');
  assert.equal(formatUnits(123n, 0), '123');
  assert.throws(() => parseUnits(0.1, 6), /decimal string/);
  assert.throws(() => parseUnits('0.0000001', 6), /decimal places/);
  assert.throws(() => parseUnits('1e3', 6), /decimal string/);
});

test('Pyth normalization handles exponents and rejects uncertainty', () => {
  assert.equal(normalizePythPrice({ price: 10_000_000_000n, conf: 100_000_000n, expo: -8 }), 100n * WAD);
  assert.equal(normalizePythPrice({ price: 100n, conf: 0n, expo: 0 }), 100n * WAD);
  assert.throws(() => normalizePythPrice({ price: 10_000_000_000n, conf: 100_000_001n, expo: -8 }), /Uncertain/);
  assert.throws(() => normalizePythPrice({ price: 100n, conf: 0n, expo: -19 }), /exponent/);
  assert.throws(() => normalizePythPrice({ price: -1n, conf: 0n, expo: -8 }), /price/);
});

test('quote eligibility mirrors pause, status, cutoff, minimum notional', () => {
  assert.throws(() => optionValue(market, 100n * WAD, 300n, true), /Trading paused/);
  assert.throws(() => optionValue({ ...market, status: 0 }, 100n * WAD, 300n), /Market closed/);
  assert.throws(() => optionValue(market, 100n * WAD, 595n), /Market closed/);
  assert.throws(() => quoteBuy(market, 999_999n, 100n * WAD, 300n), /Notional too small/);
  assert.throws(() => quoteBuy(market, 1_000_000n, 0n, 300n), /Invalid price/);
  assert.throws(() => optionValue(market, 100, 300n), /bigint/);
});

test('worthless closes can return zero while purchases reject zero value', () => {
  assert.equal(quoteSell(market, 1_000_000n, 1n * WAD, 300n).proceeds, 0n);
  assert.throws(() => quoteBuy(market, 1_000_000n, 1n * WAD, 300n), /Premium too small/);
});

test('buy/sell spread and expiry price are distinct economic quantities', () => {
  const buy = quoteBuy(market, 1_000_000_001n, 100n * WAD, 300n);
  const sale = quoteSell(market, 1_000_000_001n, 100n * WAD, 300n);
  assert(buy.premium >= sale.proceeds);
  assert(buy.fair === sale.fair || buy.fair === sale.fair + 1n);
  assert.equal(buy.premium, buy.fair + buy.fee);
  assert.equal(sale.proceeds, sale.fair - sale.fee);
  assert.equal(settlementPayout(true, market.strikePrice, 100n * WAD, 1_000_000_001n), 0n);
});

test('fees can make the purchase cost exceed maximum possible payout', () => {
  const quote = quoteBuy(market, 1_000_000_000n, 300n * WAD, 300n);
  assert.equal(quote.fair, 1_000_000_000n);
  assert.equal(quote.premium, 1_030_000_000n);
});

test('break-even thresholds respect payout flooring and impossible capped outcomes', () => {
  assert.equal(breakEvenPrice(true, 100n * WAD, 1_000_000_000n, 1_227_810n), 100_122_781_000_000_000_000n);
  const call = breakEvenPrice(true, 3n * WAD, 1_000_000n, 333_333n);
  assert.equal(settlementPayout(true, 3n * WAD, call, 1_000_000n), 333_333n);
  assert.equal(settlementPayout(true, 3n * WAD, call - 1n, 1_000_000n), 333_332n);
  const put = breakEvenPrice(false, 3n * WAD, 1_000_000n, 333_333n);
  assert.equal(settlementPayout(false, 3n * WAD, put, 1_000_000n), 333_333n);
  assert.equal(settlementPayout(false, 3n * WAD, put + 1n, 1_000_000n), 333_332n);
  assert.equal(breakEvenPrice(true, 100n * WAD, 1_000_000n, 1_000_001n), null);
  assert.equal(breakEvenPrice(false, 100n * WAD, 1_000_000n, 1_000_000n), null);
});

export const WAD: bigint;
export const USDC_UNIT: bigint;
export const BPS: bigint;
export const YEAR: bigint;
export const PRICING_STEPS: number;
export const TRADING_CUTOFF: bigint;
export const MAX_PRICE: bigint;
export const UINT256_MAX: bigint;

export interface OptionMarket {
  status: number | bigint;
  endTime: bigint;
  strikePrice: bigint;
  volatilityBps: bigint;
  feeBps: bigint;
  isCall: boolean;
}
export interface BuyQuote {
  unitValue: bigint;
  fair: bigint;
  fee: bigint;
  premium: bigint;
}
export interface SellQuote {
  unitValue: bigint;
  fair: bigint;
  fee: bigint;
  proceeds: bigint;
}
export function sqrtFloor(value: bigint): bigint;
export function optionValue(market: OptionMarket, spotPrice: bigint, now: bigint, tradingPaused?: boolean): bigint;
export function quoteBuy(market: OptionMarket, notional: bigint, spotPrice: bigint, now: bigint,
  tradingPaused?: boolean): BuyQuote;
export function quoteSell(market: OptionMarket, notional: bigint, spotPrice: bigint, now: bigint,
  tradingPaused?: boolean): SellQuote;
export function settlementPayout(isCall: boolean, strikePrice: bigint, closingPrice: bigint, notional: bigint): bigint;
export function breakEvenPrice(isCall: boolean, strikePrice: bigint, notional: bigint, premiumPaid: bigint): bigint | null;
export function normalizePythPrice(price: { price: bigint; conf: bigint; expo: number }): bigint;
export function parseUnits(value: string, decimals: number): bigint;
export function formatUnits(value: bigint, decimals: number): string;

import { quoteBuy, quoteSell, settlementPayout, parseUnits, formatUnits } from './options-math.mjs';

// Demonstration inputs. In an application, read the market and timestamp from one chain block.
const market = {
  status: 1,
  endTime: 600n,
  strikePrice: parseUnits('100', 18),
  volatilityBps: 10_000n,
  feeBps: 300n,
  isCall: true,
};
const notional = parseUnits('1000', 6);
const now = 300n;

console.table(['99', '100', '101', '150', '200'].map((price) => {
  const spot = parseUnits(price, 18);
  const sale = quoteSell(market, notional, spot, now);
  let premium;
  try {
    premium = formatUnits(quoteBuy(market, notional, spot, now).premium, 6);
  } catch (error) {
    premium = error.message;
  }
  return { spot: price, fair: formatUnits(sale.fair, 6), buy: premium,
    sell: formatUnits(sale.proceeds, 6),
    expiryPayoutAtThisPrice: formatUnits(settlementPayout(true, market.strikePrice, spot, notional), 6) };
}));

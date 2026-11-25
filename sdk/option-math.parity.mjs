// Run after `forge build`. Deploys only to an ephemeral, local Anvil instance.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { spawn, execFileSync } from 'node:child_process';
import { createServer } from 'node:net';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { WAD, MAX_PRICE, optionValue, quoteBuy, quoteSell } from './option-math.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
const foundry = process.env.FOUNDRY_BIN ?? join(homedir(), '.foundry', 'bin');
const executable = (name) => join(foundry, name + (process.platform === 'win32' ? '.exe' : ''));
const signatures = [
  'setOptionAMM(address)', 'addPair(string,bytes32)',
  'createMarket(uint256,uint64,uint64,uint256,uint256,uint256,bool)',
  'openMarket(uint256,bytes[])', 'optionValue(uint256,uint256)',
  'quoteBuy(uint256,uint256,uint256)', 'quoteSell(uint256,uint256,uint256)',
];
const selectors = new Map(signatures.map((signature) => [signature,
  execFileSync(executable('cast'), ['sig', signature], { encoding: 'utf8', windowsHide: true }).trim()]));
const word = (value) => {
  const number = typeof value === 'boolean' ? (value ? 1n : 0n) : BigInt(value);
  return (number < 0n ? (1n << 256n) + number : number).toString(16).padStart(64, '0');
};
const fixed = (signature, values) => selectors.get(signature) + values.map(word).join('');
const decode = (value) => value.slice(2).match(/.{64}/g).map((item) => BigInt('0x' + item));
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Reserve an available local port, then release it for Anvil.
const server = createServer();
await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
const port = server.address().port;
await new Promise((resolve) => server.close(resolve));
const child = spawn(executable('anvil'), ['--host', '127.0.0.1', '--port', String(port), '--timestamp', '1', '--silent'],
  { stdio: ['ignore', 'ignore', 'pipe'], windowsHide: true });
let diagnostics = '';
child.stderr.on('data', (chunk) => { diagnostics += chunk; });
child.on('error', (error) => { diagnostics += error.message; });
const url = 'http://127.0.0.1:' + port;
let rpcId = 0;
async function rpc(method, params = []) {
  const response = await fetch(url, { method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: ++rpcId, method, params }), signal: AbortSignal.timeout(10_000) });
  const payload = await response.json();
  if (payload.error) throw new Error(`${method}: ${payload.error.message}`);
  return payload.result;
}

try {
  let ready = false;
  for (let i = 0; i < 100; ++i) {
    try { await rpc('eth_chainId'); ready = true; break; } catch { await sleep(50); }
  }
  assert(ready, 'Anvil did not start: ' + diagnostics);
  const [account] = await rpc('eth_accounts');
  async function send(to, data, value = '0x0') {
    const hash = await rpc('eth_sendTransaction', [{ from: account, ...(to ? { to } : {}), data, value, gas: '0x989680' }]);
    let receipt;
    for (let i = 0; i < 100; ++i) {
      receipt = await rpc('eth_getTransactionReceipt', [hash]);
      if (receipt) break;
      await sleep(25);
    }
    assert(receipt, `Transaction did not mine: ${hash}`);
    assert.equal(receipt.status, '0x1', `Transaction reverted: ${hash}`);
    return receipt;
  }
  async function deploy(path, args = []) {
    const artifact = JSON.parse(await readFile(join(root, path), 'utf8'));
    const bytecode = artifact.bytecode.object;
    const receipt = await send(null, bytecode + args.map(word).join(''));
    return receipt.contractAddress;
  }
  async function call(data) {
    return decode(await rpc('eth_call', [{ from: account, to: amm, data }, 'latest']));
  }
  const usdc = await deploy('out/MockUSDC.sol/MockUSDC.json');
  const shares = await deploy('out/opUSDC.sol/opUSDC.json');
  const oracle = await deploy('out/OptionAMM.t.sol/OptionMockPyth.json');
  const amm = await deploy('out/OptionAMM.sol/OptionAMM.json', [usdc, oracle, shares]);
  await send(shares, fixed('setOptionAMM(address)', [amm]));
  const nameBytes = Buffer.from('BTC').toString('hex').padEnd(64, '0');
  await send(amm, selectors.get('addPair(string,bytes32)') + word(64) + word(1) + word(3) + nameBytes);

  let snapshot = await rpc('evm_snapshot');
  let valuesChecked = 0;
  let quotesChecked = 0;
  const cases = [];
  for (const isCall of [true, false]) {
    for (const duration of [86_400n, 259_200n, 604_800n, 1_209_600n, 2_592_000n]) {
      for (const volatilityBps of [100n, 10_000n, 50_000n]) {
        cases.push({ isCall, duration, volatilityBps, feeBps: volatilityBps === 100n ? 0n :
          volatilityBps === 10_000n ? 300n : 500n, strikePrice: 100n * WAD });
      }
    }
  }
  cases.push({ isCall: true, duration: 86_400n, volatilityBps: 10_000n, feeBps: 300n, strikePrice: 0n });
  cases.push({ isCall: true, duration: 2_592_000n, volatilityBps: 50_000n, feeBps: 500n, strikePrice: MAX_PRICE });

  for (const scenario of cases) {
    assert.equal(await rpc('evm_revert', [snapshot]), true);
    snapshot = await rpc('evm_snapshot');
    const { duration, volatilityBps, feeBps, isCall, strikePrice } = scenario;
    const latest = await rpc('eth_getBlockByNumber', ['latest', false]);
    const start = (BigInt(latest.timestamp) / duration + 1n) * duration;
    const endTime = start + duration;
    await send(amm, fixed('createMarket(uint256,uint64,uint64,uint256,uint256,uint256,bool)',
      [0, duration, start, strikePrice, volatilityBps, feeBps, isCall]));
    await rpc('evm_setNextBlockTimestamp', [Number(start)]);
    // ABI encoding of Update(bytes32,Price(int64,uint64,int32,uint256),uint256).
    const update = [1n, 10_000_000_000n, 0n, -8n, start, start - 1n].map(word).join('');
    const open = selectors.get('openMarket(uint256,bytes[])') + word(0) + word(64)
      + word(1) + word(32) + word(update.length / 2) + update;
    await send(amm, open, '0x1');
    const market = { status: 1, endTime, strikePrice: strikePrice || 100n * WAD,
      volatilityBps, feeBps, isCall };
    const spots = strikePrice === MAX_PRICE ? [MAX_PRICE / 2n, MAX_PRICE - 1n, MAX_PRICE] :
      [1n, 50n * WAD, 99n * WAD, 100n * WAD, 101n * WAD, 150n * WAD, 200n * WAD, 300n * WAD];
    for (const elapsed of [0n, duration / 2n, duration - 6n]) {
      if (elapsed !== 0n) {
        await rpc('evm_setNextBlockTimestamp', [Number(start + elapsed)]);
        await rpc('evm_mine');
      }
      const block = await rpc('eth_getBlockByNumber', ['latest', false]);
      const now = BigInt(block.timestamp);
      for (const spot of spots) {
        const expectedValue = optionValue(market, spot, now);
        const [actualValue] = await call(fixed('optionValue(uint256,uint256)', [0, spot]));
        assert.equal(actualValue, expectedValue, 'Unit value differs from Solidity');
        ++valuesChecked;
        for (const notional of [1_000_000n, 1_000_001n, 1_000_000_001n]) {
          const expectedSale = quoteSell(market, notional, spot, now);
          const [proceeds, saleFee] = await call(fixed('quoteSell(uint256,uint256,uint256)', [0, notional, spot]));
          assert.deepEqual([proceeds, saleFee], [expectedSale.proceeds, expectedSale.fee]);
          ++quotesChecked;
          if (expectedValue === 0n) {
            assert.throws(() => quoteBuy(market, notional, spot, now), /Premium too small/);
            await assert.rejects(() => call(fixed('quoteBuy(uint256,uint256,uint256)', [0, notional, spot])));
          } else {
            const expectedBuy = quoteBuy(market, notional, spot, now);
            const [premium, fee] = await call(fixed('quoteBuy(uint256,uint256,uint256)', [0, notional, spot]));
            assert.deepEqual([premium, fee], [expectedBuy.premium, expectedBuy.fee]);
          }
          ++quotesChecked;
        }
      }
    }
    await rpc('evm_setNextBlockTimestamp', [Number(endTime - 5n)]);
    await rpc('evm_mine');
    assert.throws(() => optionValue(market, market.strikePrice, endTime - 5n), /Market closed/);
    await assert.rejects(() => call(fixed('optionValue(uint256,uint256)', [0, market.strikePrice])));
  }
  console.log(`Solidity parity passed: ${valuesChecked} unit values, ${quotesChecked} buy/sell outcomes, `
    + `${cases.length} market configurations. All amounts match exactly.`);
} finally {
  // Close only the Anvil process started by this test.
  if (child.exitCode === null) {
    const exited = new Promise((resolve) => child.once('exit', resolve));
    child.kill();
    await exited;
  }
}

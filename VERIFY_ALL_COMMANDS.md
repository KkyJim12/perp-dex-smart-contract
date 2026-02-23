# Monad Contract Verification Commands

Complete guide to verify all deployed contracts on Monad using Sourcify.

## Prerequisites

```bash
source .env
```

## Important Notes

- Verifier URL MUST end with `/`: `https://sourcify-api-monad.blockvision.org/`
- Chain ID: 143 (Monad Mainnet)
- Use Sourcify verifier (not Etherscan)

---

## 1. Verify MockUSDC

```bash
forge verify-contract \
  --rpc-url $RPC_URL \
  --verifier sourcify \
  --verifier-url 'https://sourcify-api-monad.blockvision.org/' \
  --chain-id 143 \
  $USDC_ADDRESS \
  src/MockUSDC.sol:MockUSDC
```

**Contract:** MockUSDC  
**Path:** src/MockUSDC.sol  
**Constructor:** No arguments

---

## 2. Verify ppUSDC (Main PerpDex LP Token)

```bash
forge verify-contract \
  --rpc-url $RPC_URL \
  --verifier sourcify \
  --verifier-url 'https://sourcify-api-monad.blockvision.org/' \
  --chain-id 143 \
  $PPUSDC_ADDRESS \
  src/ppUSDC.sol:ppUSDC
```

**Contract:** ppUSDC  
**Path:** src/ppUSDC.sol  
**Constructor:** No arguments

---

## 3. Verify ocUSDC (OneClick PerpDex LP Token)

```bash
forge verify-contract \
  --rpc-url $RPC_URL \
  --verifier sourcify \
  --verifier-url 'https://sourcify-api-monad.blockvision.org/' \
  --chain-id 143 \
  $OCUSDC_ADDRESS \
  src/ocUSDC.sol:ocUSDC
```

**Contract:** ocUSDC  
**Path:** src/ocUSDC.sol  
**Constructor:** No arguments

---

## 4. Verify Main PerpDex

### Step 1: Encode constructor arguments

```bash
CONSTRUCTOR_ARGS=$(cast abi-encode "constructor(address,address,address)" $PYTH_ADDRESS $USDC_ADDRESS $PPUSDC_ADDRESS)
```

### Step 2: Verify contract

```bash
forge verify-contract \
  --rpc-url $RPC_URL \
  --verifier sourcify \
  --verifier-url 'https://sourcify-api-monad.blockvision.org/' \
  --chain-id 143 \
  --constructor-args $CONSTRUCTOR_ARGS \
  $PERPDEX_ADDRESS \
  src/PerpDex.sol:PerpDEX
```

**Contract:** PerpDEX  
**Path:** src/PerpDex.sol  
**Constructor:** `(address _pyth, address _usdc, address _ppUSDC)`

---

## 5. Verify OneClickPerpDex

### Step 1: Encode constructor arguments

```bash
CONSTRUCTOR_ARGS=$(cast abi-encode "constructor(address,address)" $USDC_ADDRESS $OCUSDC_ADDRESS)
```

### Step 2: Verify contract

```bash
forge verify-contract \
  --rpc-url $RPC_URL \
  --verifier sourcify \
  --verifier-url 'https://sourcify-api-monad.blockvision.org/' \
  --chain-id 143 \
  --constructor-args $CONSTRUCTOR_ARGS \
  $ONECLICK_PERPDEX_ADDRESS \
  src/OneClickPerpDex.sol:OneClickPerpDex
```

**Contract:** OneClickPerpDex  
**Path:** src/OneClickPerpDex.sol  
**Constructor:** `(address _usdc, address _ocUSDC)`

---

## Automated Verification

### Linux/Mac

```bash
chmod +x verify-all.sh
./verify-all.sh
```

### Windows

```cmd
verify-all.bat
```

---

## Check Verification Status

Visit Monad Explorer:
```
https://explorer.monad.xyz/
```

Search for your contract address to see verification status.

---

## Troubleshooting

### Error: "Verification failed"

1. **Check verifier URL ends with `/`**
   ```bash
   # Correct
   https://sourcify-api-monad.blockvision.org/
   
   # Wrong
   https://sourcify-api-monad.blockvision.org
   ```

2. **Verify constructor arguments are correct**
   ```bash
   # Check encoded args
   echo $CONSTRUCTOR_ARGS
   ```

3. **Ensure contract is compiled with same Solidity version**
   ```bash
   forge build
   ```

4. **Check RPC URL is accessible**
   ```bash
   cast block-number --rpc-url $RPC_URL
   ```

### Error: "Contract already verified"

This is actually success! The contract was verified in a previous attempt.

### Error: "Invalid constructor arguments"

Re-encode the constructor arguments:
```bash
# For PerpDex
cast abi-encode "constructor(address,address,address)" $PYTH_ADDRESS $USDC_ADDRESS $PPUSDC_ADDRESS

# For OneClickPerpDex
cast abi-encode "constructor(address,address)" $USDC_ADDRESS $OCUSDC_ADDRESS
```

---

## Contract Addresses (from .env)

```
USDC_ADDRESS=0x5d796275e1Bc39E7c2549B7900C3443B8a997732
PPUSDC_ADDRESS=0x1166b3f7090B0e88EB1162b7323924B550C1E8B3
PERPDEX_ADDRESS=0x9868016ea5A312E12CDaAcd6363dc07cf7c5074E
OCUSDC_ADDRESS=0xC408220EF527f1bb66Ea1D3B0Aa5870Caec52812
ONECLICK_PERPDEX_ADDRESS=0xD224566cc5a6311F538531ab41d3F66569BCB9F3
PYTH_ADDRESS=0x2880aB155794e7179c9eE2e38200202908C17B43
```

---

## Summary

Total contracts to verify: **5**

1. ✓ MockUSDC (USDC)
2. ✓ ppUSDC (Main PerpDex LP Token)
3. ✓ ocUSDC (OneClick PerpDex LP Token)
4. ✓ PerpDEX (Main Perpetual DEX)
5. ✓ OneClickPerpDex (Backend-Managed Perpetual DEX)

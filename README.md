# Monad Quick Start Guide

## 🚀 Deploy to Monad in 3 Steps

### **Step 1: Setup Environment**

Create `.env` file:

```bash
PRIVATE_KEY=0x...
PYTH_ADDRESS=0x...  # Get from Pyth docs for Monad
DEPLOY_MOCK_USDC=true
```

### **Step 2: Run Deployment Script**

```bash
chmod +x deploy-monad.sh
./deploy-monad.sh
```

The script will:
1. Deploy all contracts to Monad
2. Wait 30 seconds
3. Automatically verify all contracts
4. Show you the deployed addresses

### **Step 3: Done!**

Check your contracts on: https://explorer.monad.xyz

---

## Manual Deployment (Alternative)

### **Deploy**

```bash
forge script script/DeployWithppUSDC.s.sol \
    --rpc-url https://rpc.monad.xyz \
    --broadcast
```

### **Verify MockUSDC**

```bash
forge verify-contract \
    --rpc-url https://rpc.monad.xyz \
    --verifier sourcify \
    --verifier-url 'https://sourcify-api-monad.blockvision.org/' \
    --chain-id 143 \
    <MOCK_USDC_ADDRESS> \
    src/MockUSDC.sol:MockUSDC
```

### **Verify ppUSDC**

```bash
forge verify-contract \
    --rpc-url https://rpc.monad.xyz \
    --verifier sourcify \
    --verifier-url 'https://sourcify-api-monad.blockvision.org/' \
    --chain-id 143 \
    <PPUSDC_ADDRESS> \
    src/ppUSDC.sol:ppUSDC
```

### **Verify PerpDex**

```bash
forge verify-contract \
    --rpc-url https://rpc.monad.xyz \
    --verifier sourcify \
    --verifier-url 'https://sourcify-api-monad.blockvision.org/' \
    --chain-id 143 \
    --constructor-args $(cast abi-encode "constructor(address,address,address)" <USDC> <PYTH> <PPUSDC>) \
    <PERPDEX_ADDRESS> \
    src/PerpDex.sol:PerpDEX
```

---

## Monad Network Info

| Parameter | Value |
|-----------|-------|
| Chain ID | 143 |
| RPC URL | https://rpc.monad.xyz |
| Explorer | https://explorer.monad.xyz |
| Verifier | Sourcify |
| Verifier URL | https://sourcify-api-monad.blockvision.org/ |

---

## Important Notes

### ⚠️ Verifier URL Must End with `/`

```bash
# ✅ Correct
--verifier-url 'https://sourcify-api-monad.blockvision.org/'

# ❌ Wrong
--verifier-url 'https://sourcify-api-monad.blockvision.org'
```

### ⚠️ Always Specify Chain ID

```bash
--chain-id 143
```

### ⚠️ Use Sourcify Verifier

```bash
--verifier sourcify
```

---

## Testing After Deployment

### **Mint MockUSDC**

```bash
cast send <MOCK_USDC_ADDRESS> \
    "mint(address,uint256)" \
    <YOUR_ADDRESS> \
    1000000000 \
    --rpc-url https://rpc.monad.xyz \
    --private-key $PRIVATE_KEY
```

### **Approve USDC**

```bash
cast send <USDC_ADDRESS> \
    "approve(address,uint256)" \
    <PERPDEX_ADDRESS> \
    1000000000 \
    --rpc-url https://rpc.monad.xyz \
    --private-key $PRIVATE_KEY
```

### **Deposit LP**

```bash
cast send <PERPDEX_ADDRESS> \
    "depositLP(uint256)" \
    1000000000 \
    --rpc-url https://rpc.monad.xyz \
    --private-key $PRIVATE_KEY
```

---

## Files for Monad

- `deploy-monad.sh` - Automated deployment script
- `MONAD_DEPLOYMENT.md` - Complete Monad guide
- `MONAD_QUICK_START.md` - This file

---

## Summary

**Easiest Way:**
```bash
./deploy-monad.sh
```

**Manual Way:**
1. Deploy with forge script
2. Verify with sourcify verifier
3. Use Monad-specific verifier URL

**Key Difference from Other Chains:**
- Uses Sourcify instead of Etherscan
- Requires specific verifier URL with trailing `/`
- Chain ID is 143

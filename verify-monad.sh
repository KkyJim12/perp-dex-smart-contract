#!/bin/bash
set -e

echo "======================================"
echo "Monad Mainnet - NativeStaking Verification"
echo "======================================"
echo ""

if [ -f .env.monad ]; then
    export $(cat .env.monad | grep -v '^#' | xargs)
    echo "✓ Loaded .env.monad"
else
    echo "✗ Error: .env.monad not found"
    exit 1
fi

if [ -z "$NATIVE_STAKING_ADDRESS" ]; then
    echo "✗ Error: NATIVE_STAKING_ADDRESS not set in .env.monad"
    exit 1
fi

echo ""
echo "Contract: $NATIVE_STAKING_ADDRESS"
echo ""

# 1. Verify on Sourcify (MonadVision)
echo "1. Verifying on Sourcify (MonadVision)..."
forge verify-contract \
    $NATIVE_STAKING_ADDRESS \
    src/NativeStaking.sol:NativeStaking \
    --chain-id 143 \
    --verifier sourcify \
    --verifier-url https://sourcify-api-monad.blockvision.org \
    --watch || echo "⚠ Sourcify verification failed (may already be verified)"
echo ""

# 2. Verify on Etherscan (MonadScan)
if [ -n "$ETHERSCAN_API_KEY" ]; then
    echo "2. Verifying on Etherscan (MonadScan)..."
    forge verify-contract \
        $NATIVE_STAKING_ADDRESS \
        src/NativeStaking.sol:NativeStaking \
        --chain-id 143 \
        --verifier etherscan \
        --verifier-url "https://api.etherscan.io/v2/api?chainid=143" \
        --etherscan-api-key $ETHERSCAN_API_KEY \
        --watch || echo "⚠ Etherscan verification failed (may already be verified)"
else
    echo "2. Skipping Etherscan (MonadScan) - ETHERSCAN_API_KEY not set"
fi

echo ""
echo "======================================"
echo "Verification Complete!"
echo "======================================"
echo ""
echo "Check your contract:"
echo "MonadVision: https://monadvision.com/address/$NATIVE_STAKING_ADDRESS"
echo "MonadScan:   https://monadscan.com/address/$NATIVE_STAKING_ADDRESS"

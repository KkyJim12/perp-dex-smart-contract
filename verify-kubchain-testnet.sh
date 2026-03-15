#!/bin/bash

# Kubchain Testnet Contract Verification Script

set -e

echo "======================================"
echo "Kubchain Testnet Contract Verification"
echo "======================================"
echo ""

# Load environment variables
if [ -f .env.kubchain ]; then
    export $(cat .env.kubchain | grep -v '^#' | xargs)
    echo "✓ Loaded .env.kubchain"
else
    echo "✗ Error: .env.kubchain not found"
    exit 1
fi

# Check if addresses are set
if [ -z "$USDC_ADDRESS" ] || [ -z "$OCUSDC_ADDRESS" ] || [ -z "$ONECLICK_PERPDEX_ADDRESS" ]; then
    echo "✗ Error: Contract addresses not set in .env.kubchain"
    echo "Please deploy contracts first or update .env.kubchain with deployed addresses"
    exit 1
fi

echo ""
echo "Contract Addresses:"
echo "USDC: $USDC_ADDRESS"
echo "ocUSDC: $OCUSDC_ADDRESS"
echo "OneClickPerpDex: $ONECLICK_PERPDEX_ADDRESS"
echo ""

echo "Starting verification..."
echo "Note: Kubchain uses Blockscout which doesn't require an API key"
echo ""

# Verify Mock USDC (if deployed)
if [ "$DEPLOY_MOCK_USDC" = "true" ]; then
    echo "1. Verifying Mock USDC..."
    forge verify-contract \
        $USDC_ADDRESS \
        src/MockUSDC.sol:MockUSDC \
        --chain-id $CHAIN_ID \
        --verifier blockscout \
        --verifier-url $VERIFIER_URL \
        --watch || echo "⚠ Mock USDC verification failed (may already be verified)"
    echo ""
fi

# Verify ocUSDC
echo "2. Verifying ocUSDC..."
forge verify-contract \
    $OCUSDC_ADDRESS \
    src/ocUSDC.sol:ocUSDC \
    --chain-id $CHAIN_ID \
    --verifier blockscout \
    --verifier-url $VERIFIER_URL \
    --watch || echo "⚠ ocUSDC verification failed (may already be verified)"
echo ""

# Verify OneClickPerpDex
echo "3. Verifying OneClickPerpDex..."
forge verify-contract \
    $ONECLICK_PERPDEX_ADDRESS \
    src/OneClickPerpDex.sol:OneClickPerpDex \
    --constructor-args $(cast abi-encode "constructor(address,address)" $USDC_ADDRESS $OCUSDC_ADDRESS) \
    --chain-id $CHAIN_ID \
    --verifier blockscout \
    --verifier-url $VERIFIER_URL \
    --watch || echo "⚠ OneClickPerpDex verification failed (may already be verified)"
echo ""

echo "======================================"
echo "Verification Complete!"
echo "======================================"
echo ""
echo "Check contracts on Kubchain Explorer:"
echo "Mock USDC: https://testnet.bkcscan.com/address/$USDC_ADDRESS"
echo "ocUSDC: https://testnet.bkcscan.com/address/$OCUSDC_ADDRESS"
echo "OneClickPerpDex: https://testnet.bkcscan.com/address/$ONECLICK_PERPDEX_ADDRESS"
echo ""

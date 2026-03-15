#!/bin/bash

# Flatten contracts for manual verification on Kubchain

echo "======================================"
echo "Flattening Contracts for Verification"
echo "======================================"
echo ""

# Create flattened directory if it doesn't exist
mkdir -p flattened

echo "Flattening MockUSDC..."
forge flatten src/MockUSDC.sol --output flattened/MockUSDC_flat.sol
echo "✓ MockUSDC flattened -> flattened/MockUSDC_flat.sol"
echo ""

echo "Flattening ocUSDC..."
forge flatten src/ocUSDC.sol --output flattened/ocUSDC_flat.sol
echo "✓ ocUSDC flattened -> flattened/ocUSDC_flat.sol"
echo ""

echo "Flattening OneClickPerpDex..."
forge flatten src/OneClickPerpDex.sol --output flattened/OneClickPerpDex_flat.sol
echo "✓ OneClickPerpDex flattened -> flattened/OneClickPerpDex_flat.sol"
echo ""

echo "======================================"
echo "Flattening Complete!"
echo "======================================"
echo ""
echo "Flattened files are in the 'flattened/' directory"
echo ""

# Load environment variables if available
if [ -f .env.kubchain ]; then
    export $(cat .env.kubchain | grep -v '^#' | xargs)
    
    if [ -n "$USDC_ADDRESS" ] && [ -n "$OCUSDC_ADDRESS" ]; then
        echo "Constructor Arguments for OneClickPerpDex:"
        echo "=========================================="
        CONSTRUCTOR_ARGS=$(cast abi-encode "constructor(address,address)" $USDC_ADDRESS $OCUSDC_ADDRESS)
        echo $CONSTRUCTOR_ARGS
        echo ""
        echo "Remove the '0x' prefix when pasting into the block explorer form"
        echo ""
    fi
fi

echo "Next steps:"
echo "1. Go to https://testnet.bkcscan.com/address/<CONTRACT_ADDRESS>"
echo "2. Click 'Contract' tab -> 'Verify and Publish'"
echo "3. Use these settings:"
echo "   - Compiler: v0.8.20+commit.a1b79de6"
echo "   - Optimization: Yes, 200 runs"
echo "   - EVM Version: paris"
echo "4. Paste the flattened contract code"
echo ""
echo "See KUBCHAIN_MANUAL_VERIFY.md for detailed instructions"

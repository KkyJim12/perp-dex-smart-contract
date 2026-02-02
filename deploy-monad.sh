#!/bin/bash

# Monad Deployment Script
# This script deploys and verifies all contracts on Monad network

set -e  # Exit on error

echo "==================================="
echo "   Monad Deployment Script"
echo "==================================="
echo ""

# Check if .env exists
if [ ! -f .env ]; then
    echo "Error: .env file not found!"
    echo "Please create .env with required variables"
    exit 1
fi

# Load environment variables
source .env

# Verify required variables
if [ -z "$PRIVATE_KEY" ]; then
    echo "Error: PRIVATE_KEY not set in .env"
    exit 1
fi

if [ -z "$PYTH_ADDRESS" ]; then
    echo "Error: PYTH_ADDRESS not set in .env"
    exit 1
fi

# Monad network configuration
RPC_URL="https://rpc.monad.xyz"
CHAIN_ID=143
VERIFIER="sourcify"
VERIFIER_URL="https://sourcify-api-monad.blockvision.org/"

echo "Network: Monad"
echo "Chain ID: $CHAIN_ID"
echo "RPC URL: $RPC_URL"
echo ""

# Deploy contracts
echo "=== Step 1: Deploying Contracts ==="
echo ""

forge script script/DeployWithppUSDC.s.sol \
    --rpc-url $RPC_URL \
    --broadcast \
    --legacy

if [ $? -ne 0 ]; then
    echo ""
    echo "Error: Deployment failed!"
    exit 1
fi

echo ""
echo "=== Deployment Complete ==="
echo ""
echo "📋 CONTRACT IDENTIFICATION:"
echo "   MockUSDC.sol  = Mock USDC Token Contract"
echo "   ppUSDC.sol    = LP Token Contract (Pool Shares)"
echo "   PerpDex.sol   = Main PerpDEX Trading Contract"
echo ""
echo "Please update the addresses below from the deployment output:"
echo ""

# Prompt for deployed addresses
read -p "Enter MockUSDC.sol address (or press Enter to skip): " MOCK_USDC_ADDRESS
read -p "Enter ppUSDC.sol address: " PPUSDC_ADDRESS
read -p "Enter PerpDex.sol address: " PERPDEX_ADDRESS

if [ -z "$PPUSDC_ADDRESS" ] || [ -z "$PERPDEX_ADDRESS" ]; then
    echo "Error: ppUSDC and PerpDex addresses are required!"
    exit 1
fi

# Determine USDC address
if [ -n "$MOCK_USDC_ADDRESS" ]; then
    USDC_ADDRESS=$MOCK_USDC_ADDRESS
elif [ -n "$USDC_ADDRESS" ]; then
    USDC_ADDRESS=$USDC_ADDRESS
else
    echo "Error: No USDC address provided!"
    exit 1
fi

echo ""
echo "=== Waiting 30 seconds before verification ==="
sleep 30

echo ""
echo "=== Step 2: Verifying Contracts ==="
echo ""

# Verify MockUSDC if deployed
if [ -n "$MOCK_USDC_ADDRESS" ]; then
    echo "Verifying MockUSDC.sol at $MOCK_USDC_ADDRESS..."
    forge verify-contract \
        --rpc-url $RPC_URL \
        --verifier $VERIFIER \
        --verifier-url "$VERIFIER_URL" \
        --chain-id $CHAIN_ID \
        $MOCK_USDC_ADDRESS \
        src/MockUSDC.sol:MockUSDC
    
    if [ $? -eq 0 ]; then
        echo "✅ MockUSDC.sol verified successfully!"
    else
        echo "⚠️  MockUSDC.sol verification failed (may already be verified)"
    fi
    echo ""
fi

# Verify ppUSDC
echo "Verifying ppUSDC.sol at $PPUSDC_ADDRESS..."
forge verify-contract \
    --rpc-url $RPC_URL \
    --verifier $VERIFIER \
    --verifier-url "$VERIFIER_URL" \
    --chain-id $CHAIN_ID \
    $PPUSDC_ADDRESS \
    src/ppUSDC.sol:ppUSDC

if [ $? -eq 0 ]; then
    echo "✅ ppUSDC.sol verified successfully!"
else
    echo "⚠️  ppUSDC.sol verification failed (may already be verified)"
fi
echo ""

# Verify PerpDex
echo "Verifying PerpDex.sol at $PERPDEX_ADDRESS..."
CONSTRUCTOR_ARGS=$(cast abi-encode "constructor(address,address,address)" $USDC_ADDRESS $PYTH_ADDRESS $PPUSDC_ADDRESS)

forge verify-contract \
    --rpc-url $RPC_URL \
    --verifier $VERIFIER \
    --verifier-url "$VERIFIER_URL" \
    --chain-id $CHAIN_ID \
    --constructor-args $CONSTRUCTOR_ARGS \
    $PERPDEX_ADDRESS \
    src/PerpDex.sol:PerpDEX

if [ $? -eq 0 ]; then
    echo "✅ PerpDex.sol verified successfully!"
else
    echo "⚠️  PerpDex.sol verification failed (may already be verified)"
fi
echo ""

echo "==================================="
echo "   📋 DEPLOYMENT SUMMARY"
echo "==================================="
echo ""
echo "🔗 CONTRACT ADDRESSES:"
if [ -n "$MOCK_USDC_ADDRESS" ]; then
    echo "   MockUSDC.sol:  $MOCK_USDC_ADDRESS"
fi
echo "   ppUSDC.sol:    $PPUSDC_ADDRESS"
echo "   PerpDex.sol:   $PERPDEX_ADDRESS"
echo ""
echo "📝 CONTRACT DESCRIPTIONS:"
if [ -n "$MOCK_USDC_ADDRESS" ]; then
    echo "   MockUSDC.sol  = Mock USDC Token (for testing)"
fi
echo "   ppUSDC.sol    = LP Token Contract (Pool Shares)"
echo "   PerpDex.sol   = Main PerpDEX Trading Contract"
echo ""
echo "🌐 Explorer:     https://explorer.monad.xyz"
echo ""
echo "==================================="
echo "   Deployment Complete! 🚀"
echo "==================================="

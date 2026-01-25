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
echo "Please update the addresses below from the deployment output:"
echo ""

# Prompt for deployed addresses
read -p "Enter MockUSDC address (or press Enter to skip): " MOCK_USDC_ADDRESS
read -p "Enter ppUSDC address: " PPUSDC_ADDRESS
read -p "Enter PerpDex address: " PERPDEX_ADDRESS

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
    echo "Verifying MockUSDC at $MOCK_USDC_ADDRESS..."
    forge verify-contract \
        --rpc-url $RPC_URL \
        --verifier $VERIFIER \
        --verifier-url "$VERIFIER_URL" \
        --chain-id $CHAIN_ID \
        $MOCK_USDC_ADDRESS \
        src/MockUSDC.sol:MockUSDC
    
    if [ $? -eq 0 ]; then
        echo "✅ MockUSDC verified successfully!"
    else
        echo "⚠️  MockUSDC verification failed (may already be verified)"
    fi
    echo ""
fi

# Verify ppUSDC
echo "Verifying ppUSDC at $PPUSDC_ADDRESS..."
forge verify-contract \
    --rpc-url $RPC_URL \
    --verifier $VERIFIER \
    --verifier-url "$VERIFIER_URL" \
    --chain-id $CHAIN_ID \
    $PPUSDC_ADDRESS \
    src/ppUSDC.sol:ppUSDC

if [ $? -eq 0 ]; then
    echo "✅ ppUSDC verified successfully!"
else
    echo "⚠️  ppUSDC verification failed (may already be verified)"
fi
echo ""

# Verify PerpDex
echo "Verifying PerpDex at $PERPDEX_ADDRESS..."
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
    echo "✅ PerpDex verified successfully!"
else
    echo "⚠️  PerpDex verification failed (may already be verified)"
fi
echo ""

echo "==================================="
echo "   Deployment Summary"
echo "==================================="
echo ""
if [ -n "$MOCK_USDC_ADDRESS" ]; then
    echo "MockUSDC:  $MOCK_USDC_ADDRESS"
fi
echo "ppUSDC:    $PPUSDC_ADDRESS"
echo "PerpDex:   $PERPDEX_ADDRESS"
echo ""
echo "Explorer:  https://explorer.monad.xyz"
echo ""
echo "==================================="
echo "   Deployment Complete! 🚀"
echo "==================================="

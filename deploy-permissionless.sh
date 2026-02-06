#!/bin/bash

# Simple PerpDex Deployment Script
# This script deploys the permissionless PermissionlessPerpDex contract

set -e  # Exit on error

echo "==================================="
echo "   PermissionlessPerpDex Deployment"
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

# Network configuration (default to Monad)
RPC_URL=${RPC_URL:-"https://rpc.monad.xyz"}
CHAIN_ID=${CHAIN_ID:-143}
VERIFIER=${VERIFIER:-"sourcify"}
VERIFIER_URL=${VERIFIER_URL:-"https://sourcify-api-monad.blockvision.org/"}

echo "Network: ${NETWORK_NAME:-Monad}"
echo "Chain ID: $CHAIN_ID"
echo "RPC URL: $RPC_URL"
echo ""

# Deploy contracts
echo "=== Step 1: Deploying PermissionlessPerpDex ==="
echo ""

forge script script/DeployPermissionlessPerpDex.s.sol \
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
echo "   MockUSDC.sol        = Mock USDC Token Contract (if deployed)"
echo "   PermissionlessPerpDex.sol   = Permissionless Perpetual Trading Contract"
echo ""
echo "Please update the addresses below from the deployment output:"
echo ""

# Prompt for deployed addresses
read -p "Enter MockUSDC.sol address (or press Enter if using existing USDC): " MOCK_USDC_ADDRESS
read -p "Enter PermissionlessPerpDex.sol address: " SIMPLE_PERP_ADDRESS

if [ -z "$SIMPLE_PERP_ADDRESS" ]; then
    echo "Error: PermissionlessPerpDex address is required!"
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

# Verify PermissionlessPerpDex
echo "Verifying PermissionlessPerpDex.sol at $SIMPLE_PERP_ADDRESS..."
CONSTRUCTOR_ARGS=$(cast abi-encode "constructor(address)" $USDC_ADDRESS)

forge verify-contract \
    --rpc-url $RPC_URL \
    --verifier $VERIFIER \
    --verifier-url "$VERIFIER_URL" \
    --chain-id $CHAIN_ID \
    --constructor-args $CONSTRUCTOR_ARGS \
    $SIMPLE_PERP_ADDRESS \
    src/PermissionlessPerpDex.sol:PermissionlessPerpDex

if [ $? -eq 0 ]; then
    echo "✅ PermissionlessPerpDex.sol verified successfully!"
else
    echo "⚠️  PermissionlessPerpDex.sol verification failed (may already be verified)"
fi
echo ""

echo "==================================="
echo "   📋 DEPLOYMENT SUMMARY"
echo "==================================="
echo ""
echo "🔗 CONTRACT ADDRESSES:"
if [ -n "$MOCK_USDC_ADDRESS" ]; then
    echo "   MockUSDC.sol:      $MOCK_USDC_ADDRESS"
fi
echo "   PermissionlessPerpDex.sol: $SIMPLE_PERP_ADDRESS"
echo ""
echo "📝 CONTRACT DESCRIPTIONS:"
if [ -n "$MOCK_USDC_ADDRESS" ]; then
    echo "   MockUSDC.sol      = Mock USDC Token (for testing)"
fi
echo "   PermissionlessPerpDex.sol = Permissionless Perpetual Trading Contract"
echo ""
echo "🚀 NEXT STEPS:"
echo "   1. Authorize your backend address:"
echo "      PermissionlessPerpDex.authorizeBackend(backendAddress, true)"
echo ""
echo "   2. Users can deposit USDC:"
echo "      PermissionlessPerpDex.deposit(amount)"
echo ""
echo "   3. Backend can manage positions:"
echo "      - openPosition(user, pair, isLong, margin, leverage, entryPrice)"
echo "      - closePosition(positionId, exitPrice, reason)"
echo "      - liquidatePosition(positionId, liquidationPrice)"
echo ""
echo "🌐 Explorer: https://explorer.monad.xyz"
echo ""
echo "==================================="
echo "   Deployment Complete! 🚀"
echo "==================================="

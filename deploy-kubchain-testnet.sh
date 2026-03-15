#!/bin/bash

# Kubchain Testnet Deployment Script
# Deploys OneClickPerpDex, ocUSDC, and optionally Mock USDC

set -e

echo "======================================"
echo "Kubchain Testnet Deployment"
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

echo ""
echo "Network: Kubchain Testnet"
echo "Chain ID: $CHAIN_ID"
echo "RPC URL: $RPC_URL"
echo "Deploy Mock USDC: $DEPLOY_MOCK_USDC"
echo ""

# Confirm deployment
read -p "Continue with deployment? (y/n) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Deployment cancelled"
    exit 1
fi

echo ""
echo "Starting deployment..."
echo ""

# Run deployment
forge script script/DeployKubchainTestnet.s.sol:DeployKubchainTestnet \
    --rpc-url $RPC_URL \
    --private-key $PRIVATE_KEY \
    --legacy \
    --broadcast \
    -vvvv

echo ""
echo "======================================"
echo "Deployment Complete!"
echo "======================================"
echo ""
echo "Check broadcast/DeployKubchainTestnet.s.sol/25925/run-latest.json for details"
echo ""
echo "Next steps:"
echo "1. Update .env.kubchain with deployed addresses"
echo "2. Authorize backend address"
echo "3. Add initial liquidity"

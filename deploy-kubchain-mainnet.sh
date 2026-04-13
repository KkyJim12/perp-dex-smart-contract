#!/bin/bash
set -e

echo "======================================"
echo "Kubchain Mainnet - Full Deployment"
echo "OneClickPerpDex + NativeStaking"
echo "======================================"

if [ -f .env.kubchain.mainnet ]; then
    export $(cat .env.kubchain.mainnet | grep -v '^#' | xargs)
    echo "✓ Loaded .env.kubchain.mainnet"
else
    echo "✗ Error: .env.kubchain.mainnet not found"
    exit 1
fi

if [ -z "$PRIVATE_KEY" ]; then
    echo "✗ Error: PRIVATE_KEY not set"
    exit 1
fi

echo ""
echo "Network: Kubchain Mainnet"
echo "Chain ID: $CHAIN_ID"
echo "RPC URL: $RPC_URL"
echo "Backend: $BACKEND_ADDRESS"
echo ""

read -p "⚠ This is MAINNET. Continue? (y/n) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then exit 1; fi

echo ""
forge script script/DeployKubchainMainnet.s.sol:DeployKubchainMainnet \
    --rpc-url $RPC_URL \
    --private-key $PRIVATE_KEY \
    --legacy \
    --broadcast \
    -vvvv

echo ""
echo "Done! Update .env.kubchain.mainnet with deployed addresses."

#!/bin/bash
set -e

echo "======================================"
echo "Monad Mainnet - NativeStaking Deployment"
echo "======================================"

if [ -f .env.monad ]; then
    export $(cat .env.monad | grep -v '^#' | xargs)
    echo "✓ Loaded .env.monad"
else
    echo "✗ Error: .env.monad not found"
    exit 1
fi

if [ -z "$PRIVATE_KEY" ]; then
    echo "✗ Error: PRIVATE_KEY not set in .env.monad"
    exit 1
fi

echo ""
echo "Network: Monad Mainnet"
echo "Chain ID: $CHAIN_ID"
echo "RPC URL: $RPC_URL"
echo ""

read -p "Continue? (y/n) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then exit 1; fi

echo ""
forge script script/DeployNativeStakingMonad.s.sol:DeployNativeStakingMonad \
    --rpc-url $RPC_URL \
    --private-key $PRIVATE_KEY \
    --broadcast \
    -vvvv

echo ""
echo "Done! Update .env.monad with the deployed address."

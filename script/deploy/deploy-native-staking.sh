#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../.."

ENV_FILE="${1:-.env}"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "Error: environment file not found: $ENV_FILE" >&2
    exit 1
fi

# The environment file is local-only and must contain shell-compatible KEY=VALUE lines.
set -a
source "$ENV_FILE"
set +a

for REQUIRED_VAR in PRIVATE_KEY RPC_URL CHAIN_ID; do
    if [[ -z "${!REQUIRED_VAR:-}" ]]; then
        echo "Error: $REQUIRED_VAR is not set in $ENV_FILE" >&2
        exit 1
    fi
done

if ! command -v forge >/dev/null 2>&1 || ! command -v cast >/dev/null 2>&1; then
    echo "Error: Foundry (forge and cast) must be installed and on PATH." >&2
    exit 1
fi

ACTUAL_CHAIN_ID="$(cast chain-id --rpc-url "$RPC_URL")"
if [[ "$ACTUAL_CHAIN_ID" != "$CHAIN_ID" ]]; then
    echo "Error: RPC chain ID is $ACTUAL_CHAIN_ID but CHAIN_ID is $CHAIN_ID." >&2
    exit 1
fi

DEPLOYER_ADDRESS="$(cast wallet address --private-key "$PRIVATE_KEY")"
DEPLOYER_BALANCE="$(cast balance "$DEPLOYER_ADDRESS" --rpc-url "$RPC_URL")"
if [[ "$DEPLOYER_BALANCE" == "0" ]]; then
    echo "Error: deployer has no native-token balance for gas." >&2
    exit 1
fi

echo "======================================"
echo "NativeStaking deployment"
echo "======================================"
echo "Chain ID: $CHAIN_ID"
echo "RPC URL: $RPC_URL"
echo "Deployer: $DEPLOYER_ADDRESS"
echo "AVAX balance (wei): $DEPLOYER_BALANCE"
if [[ -n "${BACKEND_ADDRESS:-}" ]]; then
    echo "Backend to authorize: $BACKEND_ADDRESS"
fi
echo

if [[ "$CHAIN_ID" == "43114" ]]; then
    read -r -p "WARNING: This deploys to Avalanche mainnet. Continue? (y/N) " REPLY
else
    read -r -p "Deploy NativeStaking? (y/N) " REPLY
fi

if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
    echo "Deployment cancelled."
    exit 0
fi

forge script script/DeployNativeStaking.s.sol:DeployNativeStaking \
    --rpc-url "$RPC_URL" \
    --broadcast \
    -vvvv

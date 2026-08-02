#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${1:-.env}"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "Error: environment file not found: $ENV_FILE" >&2
    exit 1
fi

set -a
source "$ENV_FILE"
set +a

for REQUIRED_VAR in RPC_URL CHAIN_ID NATIVE_STAKING_ADDRESS; do
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

case "$CHAIN_ID" in
    43114)
        SNOWTRACE_API_URL="https://api.snowtrace.io/api"
        EXPLORER_URL="https://snowtrace.io/address/$NATIVE_STAKING_ADDRESS"
        ;;
    43113)
        SNOWTRACE_API_URL="https://api-testnet.snowtrace.io/api"
        EXPLORER_URL="https://testnet.snowtrace.io/address/$NATIVE_STAKING_ADDRESS"
        ;;
    *)
        echo "Error: Snowtrace verification is configured only for Avalanche C-Chain (43114) or Fuji (43113)." >&2
        exit 1
        ;;
esac

ONCHAIN_CODE="$(cast code "$NATIVE_STAKING_ADDRESS" --rpc-url "$RPC_URL")"
if [[ "$ONCHAIN_CODE" == "0x" ]]; then
    echo "Error: no contract code found at $NATIVE_STAKING_ADDRESS." >&2
    exit 1
fi

# Snowtrace's free tier accepts a placeholder API key. Set SNOWTRACE_API_KEY to
# use a Routescan/Snowtrace key if your account requires one.
SNOWTRACE_API_KEY="${SNOWTRACE_API_KEY:-placeholder}"

echo "Submitting NativeStaking for Snowtrace verification"
echo "Chain ID: $CHAIN_ID"
echo "Contract: $NATIVE_STAKING_ADDRESS"
echo "Explorer: $EXPLORER_URL"

forge verify-contract \
    --chain "$CHAIN_ID" \
    --watch \
    --via-ir \
    --num-of-optimizations 200 \
    --verifier custom \
    --verifier-url "$SNOWTRACE_API_URL" \
    --verifier-api-key "$SNOWTRACE_API_KEY" \
    "$NATIVE_STAKING_ADDRESS" \
    src/NativeStaking.sol:NativeStaking

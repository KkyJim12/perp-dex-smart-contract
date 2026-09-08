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
        EXPLORER_URL="https://snowscan.xyz/address/$NATIVE_STAKING_ADDRESS"
        ;;
    43113)
        EXPLORER_URL="https://testnet.snowscan.xyz/address/$NATIVE_STAKING_ADDRESS"
        ;;
    *)
        echo "Error: NativeStaking verification is configured only for Avalanche C-Chain (43114) or Fuji (43113)." >&2
        exit 1
        ;;
esac

ONCHAIN_CODE="$(cast code "$NATIVE_STAKING_ADDRESS" --rpc-url "$RPC_URL")"
if [[ "$ONCHAIN_CODE" == "0x" ]]; then
    echo "Error: no contract code found at $NATIVE_STAKING_ADDRESS." >&2
    exit 1
fi

# Forge adds chainid from --chain; keep the endpoint free of query parameters.
VERIFIER_URL="https://api.etherscan.io/v2/api"
: "${ETHERSCAN_API_KEY:?Error: ETHERSCAN_API_KEY is required for Etherscan API V2}"

echo "Submitting NativeStaking for SnowScan verification through Etherscan API V2"
echo "Chain ID: $CHAIN_ID"
echo "Contract: $NATIVE_STAKING_ADDRESS"
echo "Explorer: $EXPLORER_URL"
echo "Verifier URL: $VERIFIER_URL"

forge verify-contract \
    --chain "$CHAIN_ID" \
    --watch \
    --via-ir \
    --num-of-optimizations 200 \
    --verifier etherscan \
    --verifier-url "$VERIFIER_URL" \
    --etherscan-api-key "$ETHERSCAN_API_KEY" \
    "$NATIVE_STAKING_ADDRESS" \
    src/NativeStaking.sol:NativeStaking

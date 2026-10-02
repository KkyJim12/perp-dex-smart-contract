#!/usr/bin/env bash
set -euo pipefail

# Run owner-only post-deployment initialization.
# Usage: bash script/deploy/initialize-deployment.sh [environment-file]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../.."

ENV_FILE="${1:-.env}"
if [[ ! -f "$ENV_FILE" ]]; then
    echo "Error: environment file not found: $ENV_FILE" >&2
    exit 1
fi

set -a
# shellcheck disable=SC1090
source <(tr -d '\r' < "$ENV_FILE")
set +a

for command in forge cast; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "Error: $command is not installed or not on PATH." >&2
        exit 1
    fi
done

: "${PRIVATE_KEY:?Error: PRIVATE_KEY is required}"
: "${RPC_URL:?Error: RPC_URL is required}"
: "${CHAIN_ID:?Error: CHAIN_ID is required}"
: "${USDC_ADDRESS:?Error: USDC_ADDRESS is required}"
: "${ONECLICK_PERPDEX_ADDRESS:?Error: ONECLICK_PERPDEX_ADDRESS is required}"
: "${BACKEND_ADDRESS:?Error: BACKEND_ADDRESS is required}"

if [[ ! "$BACKEND_ADDRESS" =~ ^0x[0-9a-fA-F]{40}$ || "$BACKEND_ADDRESS" == "0x0000000000000000000000000000000000000000" ]]; then
    echo "Error: BACKEND_ADDRESS must be a valid, nonzero Ethereum address." >&2
    exit 1
fi

ACTUAL_CHAIN_ID="$(cast chain-id --rpc-url "$RPC_URL")"
if [[ "$ACTUAL_CHAIN_ID" != "$CHAIN_ID" ]]; then
    echo "Error: RPC returned chain ID $ACTUAL_CHAIN_ID; expected CHAIN_ID $CHAIN_ID." >&2
    exit 1
fi

if [[ "${INITIALIZE_CONFIRM:-}" != "yes" ]]; then
    read -r -p "Mint MockUSDC when enabled and authorize $BACKEND_ADDRESS as OneClick backend? (y/N) " REPLY
    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
        echo "Initialization cancelled. Set INITIALIZE_CONFIRM=yes for non-interactive use."
        exit 0
    fi
fi

FORGE_ARGS=(
    script script/InitializeDeployment.s.sol:InitializeDeployment
    --rpc-url "$RPC_URL"
    --broadcast
    --slow
    -vvvv
)

if [[ "$CHAIN_ID" == "56" ]]; then
    FORGE_ARGS+=(--legacy)
fi

forge "${FORGE_ARGS[@]}"

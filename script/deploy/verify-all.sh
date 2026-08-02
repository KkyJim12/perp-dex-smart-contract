#!/usr/bin/env bash
set -uo pipefail

# Verify the complete deployment on Avalanche Snowtrace.
# Supports Avalanche C-Chain mainnet (43114) and Fuji (43113).

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [[ ! -f .env ]]; then
    echo -e "${RED}Error: .env file not found.${NC}" >&2
    exit 1
fi

# Export .env variables while preserving inline comments and quoted values.
set -a
# shellcheck disable=SC1091
source .env
set +a

for command in forge cast; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo -e "${RED}Error: ${command} is not installed or not on PATH.${NC}" >&2
        exit 1
    fi
done

: "${RPC_URL:?Error: RPC_URL is required}"
: "${CHAIN_ID:?Error: CHAIN_ID is required}"

case "$CHAIN_ID" in
    43114)
        NETWORK_NAME="Avalanche C-Chain"
        VERIFIER_URL="${AVALANCHE_VERIFIER_URL:-https://api.snowtrace.io/api}"
        EXPLORER_URL="https://snowtrace.io"
        ;;
    43113)
        NETWORK_NAME="Avalanche Fuji"
        VERIFIER_URL="${AVALANCHE_VERIFIER_URL:-https://api-testnet.snowtrace.io/api}"
        EXPLORER_URL="https://testnet.snowtrace.io"
        ;;
    *)
        echo -e "${RED}Error: unsupported Avalanche chain ID ${CHAIN_ID}.${NC}" >&2
        echo "Expected 43114 (mainnet) or 43113 (Fuji)." >&2
        exit 1
        ;;
esac

ACTUAL_CHAIN_ID="$(cast chain-id --rpc-url "$RPC_URL")"
if [[ "$ACTUAL_CHAIN_ID" != "$CHAIN_ID" ]]; then
    echo -e "${RED}Error: RPC returned chain ID ${ACTUAL_CHAIN_ID}; expected ${CHAIN_ID}.${NC}" >&2
    exit 1
fi

is_address() {
    [[ "${1:-}" =~ ^0x[0-9a-fA-F]{40}$ ]]
}

require_address() {
    local name=$1
    local value=${!name:-}

    if ! is_address "$value"; then
        echo -e "${RED}Error: ${name} is missing or invalid: '${value}'${NC}" >&2
        exit 1
    fi
}

has_code() {
    local address=$1
    [[ "$(cast code "$address" --rpc-url "$RPC_URL")" != "0x" ]]
}

# These addresses are needed to reconstruct constructor arguments.
require_address USDC_ADDRESS
require_address PPUSDC_ADDRESS
require_address PERPDEX_ADDRESS
require_address PYTH_ADDRESS
require_address OCUSDC_ADDRESS
require_address ONECLICK_PERPDEX_ADDRESS

echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}${NETWORK_NAME} Contract Verification${NC}"
echo -e "${YELLOW}========================================${NC}"
echo "Chain ID:     $CHAIN_ID"
echo "RPC URL:      $RPC_URL"
echo "Verifier URL: $VERIFIER_URL"
echo ""

VERIFIER_API_KEY="${SNOWTRACE_API_KEY:-placeholder}"
SUCCESS_COUNT=0
FAILURE_COUNT=0

verify_contract() {
    local address=$1
    local contract=$2
    local constructor_args=${3:-}
    local name=${contract##*:}

    echo -e "${YELLOW}Verifying ${name}...${NC}"
    echo "Address:  $address"
    echo "Contract: $contract"

    if ! has_code "$address"; then
        echo -e "${RED}Failed: no contract bytecode at ${address}.${NC}"
        FAILURE_COUNT=$((FAILURE_COUNT + 1))
        echo ""
        return
    fi

    local args=(
        verify-contract
        --rpc-url "$RPC_URL"
        --chain "$CHAIN_ID"
        --verifier custom
        --verifier-url "$VERIFIER_URL"
        --verifier-api-key "$VERIFIER_API_KEY"
        --num-of-optimizations 1
        --via-ir
        --watch
    )

    if [[ -n "$constructor_args" ]]; then
        args+=(--constructor-args "$constructor_args")
    fi

    args+=("$address" "$contract")

    if forge "${args[@]}"; then
        echo -e "${GREEN}Verified ${name}.${NC}"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        echo -e "${RED}Failed to verify ${name}.${NC}"
        FAILURE_COUNT=$((FAILURE_COUNT + 1))
    fi
    echo ""
}

# Only verify USDC as MockUSDC when this deployment actually created the mock.
if [[ "${DEPLOY_MOCK_USDC:-false}" == "true" ]]; then
    verify_contract "$USDC_ADDRESS" "src/MockUSDC.sol:MockUSDC"
else
    echo "Skipping USDC source verification because DEPLOY_MOCK_USDC is not true."
    echo ""
fi

verify_contract "$PPUSDC_ADDRESS" "src/ppUSDC.sol:ppUSDC"
verify_contract "$OCUSDC_ADDRESS" "src/ocUSDC.sol:ocUSDC"

# PerpDEX constructor: (_usdc, _pyth, _ppUSDC)
PERPDEX_ARGS="$(
    cast abi-encode \
        "constructor(address,address,address)" \
        "$USDC_ADDRESS" \
        "$PYTH_ADDRESS" \
        "$PPUSDC_ADDRESS"
)"
verify_contract \
    "$PERPDEX_ADDRESS" \
    "src/PerpDex.sol:PerpDEX" \
    "$PERPDEX_ARGS"

# OneClickPerpDex constructor: (_usdc, _ocUSDC)
ONECLICK_ARGS="$(
    cast abi-encode \
        "constructor(address,address)" \
        "$USDC_ADDRESS" \
        "$OCUSDC_ADDRESS"
)"
verify_contract \
    "$ONECLICK_PERPDEX_ADDRESS" \
    "src/OneClickPerpDex.sol:OneClickPerpDex" \
    "$ONECLICK_ARGS"

echo -e "${YELLOW}========================================${NC}"
echo "Verification complete: ${SUCCESS_COUNT} succeeded, ${FAILURE_COUNT} failed."
echo "Explorer: ${EXPLORER_URL}"
echo -e "${YELLOW}========================================${NC}"

if (( FAILURE_COUNT > 0 )); then
    exit 1
fi

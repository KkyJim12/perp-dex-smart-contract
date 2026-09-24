#!/usr/bin/env bash
set -euo pipefail

# Verify the complete deployment on the network configured in .env.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../.."

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [[ ! -f .env ]]; then
    echo -e "${RED}Error: .env file not found.${NC}" >&2
    exit 1
fi

# Export .env variables while preserving inline comments and quoted values.
# Strip CRLF carriage returns so the script works from Git Bash on Windows too.
set -a
# shellcheck disable=SC1091
source <(tr -d '\r' < .env)
set +a

for command in forge cast; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo -e "${RED}Error: ${command} is not installed or not on PATH.${NC}" >&2
        exit 1
    fi
done

: "${RPC_URL:?Error: RPC_URL is required}"
: "${CHAIN_ID:?Error: CHAIN_ID is required}"

VERIFIER="etherscan"
# Etherscan API V2 requires `chainid` in the request URL.  `--chain` selects
# Foundry's chain configuration but is not forwarded as this API parameter.
VERIFIER_URL="https://api.etherscan.io/v2/api?chainid=${CHAIN_ID}"
VERIFIER_API_KEY="${ETHERSCAN_API_KEY:-}"
REQUIRES_API_KEY=true

case "$CHAIN_ID" in
    143)
        NETWORK_NAME="${NETWORK_NAME:-Monad Mainnet}"
        EXPLORER_URL="${EXPLORER_URL:-https://monadvision.com}"
        VERIFIER="sourcify"
        VERIFIER_URL="${MONAD_SOURCIFY_URL:-https://sourcify-api-monad.blockvision.org/}"
        REQUIRES_API_KEY=false
        ;;
    10143)
        NETWORK_NAME="${NETWORK_NAME:-Monad Testnet}"
        EXPLORER_URL="${EXPLORER_URL:-https://testnet.monadvision.com}"
        VERIFIER="sourcify"
        VERIFIER_URL="${MONAD_SOURCIFY_URL:-https://sourcify-api-monad.blockvision.org/}"
        REQUIRES_API_KEY=false
        ;;
    8453)
        NETWORK_NAME="${NETWORK_NAME:-Base Mainnet}"
        EXPLORER_URL="${EXPLORER_URL:-https://basescan.org}"
        ;;
    43114)
        NETWORK_NAME="${NETWORK_NAME:-Avalanche C-Chain}"
        EXPLORER_URL="${EXPLORER_URL:-https://snowscan.xyz}"
        ;;
    *)
        NETWORK_NAME="${NETWORK_NAME:-Chain ${CHAIN_ID}}"
        EXPLORER_URL="${EXPLORER_URL:-Not configured}"
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
require_address OPUSDC_ADDRESS
require_address OPTIONS_AMM_ADDRESS
require_address PMUSDC_ADDRESS
require_address PREDICTION_MARKET_AMM_ADDRESS

echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}${NETWORK_NAME} Contract Verification${NC}"
echo -e "${YELLOW}========================================${NC}"
echo "Chain ID:     $CHAIN_ID"
echo "Verifier:     $VERIFIER"
echo "Verifier URL: $VERIFIER_URL"
echo ""

if [[ "$REQUIRES_API_KEY" == true && -z "$VERIFIER_API_KEY" ]]; then
    echo -e "${RED}Error: ETHERSCAN_API_KEY is required for Etherscan API V2.${NC}" >&2
    exit 1
fi

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
        --verifier "$VERIFIER"
        --verifier-url "$VERIFIER_URL"
        --num-of-optimizations 1
        --via-ir
    )

    if [[ "$REQUIRES_API_KEY" == true ]]; then
        args+=(--etherscan-api-key "$VERIFIER_API_KEY" --watch)
    fi

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
verify_contract "$OPUSDC_ADDRESS" "src/opUSDC.sol:opUSDC"

# PerpDex constructor: (_usdc, _pyth, _ppUSDC)
PERPDEX_ARGS="$(
    cast abi-encode \
        "constructor(address,address,address)" \
        "$USDC_ADDRESS" \
        "$PYTH_ADDRESS" \
        "$PPUSDC_ADDRESS"
)"
verify_contract \
    "$PERPDEX_ADDRESS" \
    "src/PerpDex.sol:PerpDex" \
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

# OptionsAMM constructor: (usdc_, pyth_, opUSDC_)
OPTIONS_ARGS="$(
    cast abi-encode \
        "constructor(address,address,address)" \
        "$USDC_ADDRESS" \
        "$PYTH_ADDRESS" \
        "$OPUSDC_ADDRESS"
)"
verify_contract "$OPTIONS_AMM_ADDRESS" "src/OptionsAMM.sol:OptionsAMM" "$OPTIONS_ARGS"

# Read immutable prediction settings from the deployed vault so verification
# still works if the deployment fee in .env has changed.
PREDICTION_FEEDS=()
for index in 0 1 2; do
    PREDICTION_FEEDS+=("$(cast call "$PREDICTION_MARKET_AMM_ADDRESS" \
        'priceIds(uint256)(bytes32)' "$index" --rpc-url "$RPC_URL")")
done
PREDICTION_FEE="$(cast call "$PREDICTION_MARKET_AMM_ADDRESS" \
    'feeBps()(uint256)' --rpc-url "$RPC_URL")"
PREDICTION_ARGS="$(
    cast abi-encode \
        "constructor(address,address,bytes32[3],uint256)" \
        "$USDC_ADDRESS" \
        "$PYTH_ADDRESS" \
        "[${PREDICTION_FEEDS[0]},${PREDICTION_FEEDS[1]},${PREDICTION_FEEDS[2]}]" \
        "$PREDICTION_FEE"
)"
verify_contract "$PREDICTION_MARKET_AMM_ADDRESS" \
    "src/PredictionMarketAMM.sol:PredictionMarketAMM" "$PREDICTION_ARGS"

# pmUSDC is created by PredictionMarketAMM with the vault as its sole argument.
PMUSDC_ARGS="$(cast abi-encode 'constructor(address)' "$PREDICTION_MARKET_AMM_ADDRESS")"
verify_contract "$PMUSDC_ADDRESS" "src/pmUSDC.sol:pmUSDC" "$PMUSDC_ARGS"

echo -e "${YELLOW}========================================${NC}"
echo "Verification complete: ${SUCCESS_COUNT} succeeded, ${FAILURE_COUNT} failed."
echo "Explorer: ${EXPLORER_URL}"
echo -e "${YELLOW}========================================${NC}"

if (( FAILURE_COUNT > 0 )); then
    exit 1
fi

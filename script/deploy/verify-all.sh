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

url_encode() {
    local LC_ALL=C value=$1 encoded='' character escaped i
    for (( i=0; i<${#value}; i++ )); do
        character=${value:i:1}
        case "$character" in
            [a-zA-Z0-9.~_-]) encoded+=$character ;;
            *) printf -v escaped '%%%02X' "'$character"; encoded+=$escaped ;;
        esac
    done
    printf '%s' "$encoded"
}

VERIFIER="etherscan"
# Etherscan API V2 requires `chainid` in the request URL.  `--chain` selects
# Foundry's chain configuration but is not forwarded as this API parameter.
VERIFIER_URL="https://api.etherscan.io/v2/api?chainid=${CHAIN_ID}"
VERIFIER_API_KEY="${ETHERSCAN_API_KEY:-}"
REQUIRES_API_KEY=true

case "$CHAIN_ID" in
    4663)
        NETWORK_NAME="${NETWORK_NAME:-Robinhood Chain}"
        EXPLORER_URL="${EXPLORER_URL:-https://robinhoodchain.blockscout.com}"
        VERIFIER="sourcify"
        VERIFIER_URL="https://sourcify.dev/server/"
        REQUIRES_API_KEY=false
        ;;
    46630)
        NETWORK_NAME="${NETWORK_NAME:-Robinhood Chain Testnet}"
        EXPLORER_URL="${EXPLORER_URL:-https://explorer.testnet.chain.robinhood.com}"
        VERIFIER="sourcify"
        VERIFIER_URL="https://sourcify.dev/server/"
        REQUIRES_API_KEY=false
        ;;
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
VERIFIER_DISPLAY_URL="$VERIFIER_URL"

# The explorer's public API can reject CLI requests with a Cloudflare challenge.
# Sourcify supports both Robinhood networks without an API key. On mainnet, a
# Blockscout PRO key selects its documented verification gateway instead.
if [[ "$CHAIN_ID" == "4663" && -n "${BLOCKSCOUT_API_KEY:-}" ]]; then
    VERIFIER="blockscout"
    VERIFIER_API_KEY="$BLOCKSCOUT_API_KEY"
    # Foundry's Blockscout provider omits apikey from its submitted form, even
    # when --etherscan-api-key is set. The PRO gateway authenticates the query.
    VERIFIER_API_KEY_ENCODED="$(url_encode "$VERIFIER_API_KEY")"
    VERIFIER_URL="https://api.blockscout.com/v2/api?chain_id=${CHAIN_ID}&apikey=${VERIFIER_API_KEY_ENCODED}"
    VERIFIER_DISPLAY_URL="https://api.blockscout.com/v2/api?chain_id=${CHAIN_ID}&apikey=[redacted]"
    REQUIRES_API_KEY=true
fi

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
require_address OPTION_AMM_ADDRESS
require_address PMUSDC_ADDRESS
require_address PREDICTION_MARKET_AMM_ADDRESS

echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}${NETWORK_NAME} Contract Verification${NC}"
echo -e "${YELLOW}========================================${NC}"
echo "Chain ID:     $CHAIN_ID"
echo "Verifier:     $VERIFIER"
echo "Verifier URL: $VERIFIER_DISPLAY_URL"
echo ""

if [[ "$REQUIRES_API_KEY" == true && -z "$VERIFIER_API_KEY" ]]; then
    echo -e "${RED}Error: ETHERSCAN_API_KEY is required for Etherscan API V2.${NC}" >&2
    exit 1
fi

SUCCESS_COUNT=0
FAILURE_COUNT=0

redact_verifier_output() {
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=${line//"$VERIFIER_API_KEY"/[redacted]}
        line=${line//"$VERIFIER_API_KEY_ENCODED"/[redacted]}
        printf '%s\n' "$line"
    done
}

verify_contract() {
    local address=$1
    local contract=$2
    local constructor_args=${3:-}
    local name=${contract##*:}

    echo -e "${YELLOW}Verifying ${name}...${NC}"
    echo "Address:  $address"
    echo "Contract: $contract"
    echo "Provider: $VERIFIER"

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
        args+=(--etherscan-api-key "$VERIFIER_API_KEY")
    fi

    if [[ "$VERIFIER" != "sourcify" || "$CHAIN_ID" == "4663" || "$CHAIN_ID" == "46630" ]]; then
        args+=(--watch)
    fi

    if [[ "$VERIFIER" == "blockscout" ]]; then
        # Skip the preliminary getabi request, which can be Cloudflare-blocked.
        # Submission and status polling still depend on the explorer API.
        args+=(--skip-is-verified-check)
    fi

    if [[ -n "$constructor_args" ]]; then
        args+=(--constructor-args "$constructor_args")
    fi

    args+=("$address" "$contract")

    local verification_exit=0
    if [[ "$VERIFIER" == "sourcify" ]]; then
        # Foundry can select Etherscan when an unrelated Etherscan key is set,
        # even with --verifier sourcify. Preserve an explicitly empty key in
        # this child process so dotenv cannot restore it from .env.
        ETHERSCAN_API_KEY= VERIFIER_API_KEY= forge "${args[@]}" || verification_exit=$?
    elif [[ "$VERIFIER" == "blockscout" ]]; then
        forge "${args[@]}" 2>&1 | redact_verifier_output || verification_exit=$?
    else
        forge "${args[@]}" || verification_exit=$?
    fi

    if (( verification_exit == 0 )); then
        echo -e "${GREEN}Verified ${name} on ${VERIFIER}.${NC}"
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

# OptionAMM constructor: (usdc_, pyth_, opUSDC_)
OPTION_ARGS="$(
    cast abi-encode \
        "constructor(address,address,address)" \
        "$USDC_ADDRESS" \
        "$PYTH_ADDRESS" \
        "$OPUSDC_ADDRESS"
)"
verify_contract "$OPTION_AMM_ADDRESS" "src/OptionAMM.sol:OptionAMM" "$OPTION_ARGS"

# Read immutable prediction settings from the deployed vault so verification
# still works if the deployment fee in .env has changed.
PREDICTION_FEE="$(cast call "$PREDICTION_MARKET_AMM_ADDRESS" \
    'feeBps()(uint256)' --rpc-url "$RPC_URL")"
PREDICTION_ARGS="$(
    cast abi-encode \
        "constructor(address,address,uint256)" \
        "$USDC_ADDRESS" \
        "$PYTH_ADDRESS" \
        "$PREDICTION_FEE"
)"
verify_contract "$PREDICTION_MARKET_AMM_ADDRESS" \
    "src/PredictionMarketAMM.sol:PredictionMarketAMM" "$PREDICTION_ARGS"

# pmUSDC is created by PredictionMarketAMM with the vault as its sole argument.
PMUSDC_ARGS="$(cast abi-encode 'constructor(address)' "$PREDICTION_MARKET_AMM_ADDRESS")"
verify_contract "$PMUSDC_ADDRESS" "src/pmUSDC.sol:pmUSDC" "$PMUSDC_ARGS"

echo -e "${YELLOW}========================================${NC}"
echo "Verification complete: ${SUCCESS_COUNT} succeeded, ${FAILURE_COUNT} failed."
echo "Provider: ${VERIFIER}"
if [[ "$VERIFIER" == "sourcify" && ( "$CHAIN_ID" == "4663" || "$CHAIN_ID" == "46630" ) ]]; then
    echo "Verification records: https://sourcify.dev/server/v2/contract/${CHAIN_ID}/<address>"
    echo "Blockscout's verified badge requires a separate import or verification."
fi
echo "Explorer: ${EXPLORER_URL}"
echo -e "${YELLOW}========================================${NC}"

if (( FAILURE_COUNT > 0 )); then
    exit 1
fi

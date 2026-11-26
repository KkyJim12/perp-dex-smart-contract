#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../.."

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    echo "Usage: bash script/deploy/verify-atlas.sh [environment-file]"
    echo "Verify the three Atlas vaults and their LP tokens (default environment: .env)."
    exit 0
fi
if [[ "$#" -gt 1 || "${1:-}" == -* ]]; then
    echo "Usage: bash script/deploy/verify-atlas.sh [environment-file]" >&2
    exit 1
fi
ENV_FILE="${1:-.env}"
if [[ ! -f "$ENV_FILE" ]]; then
    echo "Error: environment file not found: $ENV_FILE" >&2
    exit 1
fi
set -a
# shellcheck disable=SC1090
source <(tr -d '\r' < "$ENV_FILE")
set +a

for REQUIRED_VAR in RPC_URL CHAIN_ID; do
    if [[ -z "${!REQUIRED_VAR:-}" ]]; then
        echo "Error: $REQUIRED_VAR is required in $ENV_FILE." >&2
        exit 1
    fi
done

# Match the deployment runner's discovery for Git Bash and custom installations.
if ! command -v forge >/dev/null 2>&1 || ! command -v cast >/dev/null 2>&1; then
    FOUNDRY_PATHS=()
    if [[ -n "${FOUNDRY_DIR:-}" ]]; then FOUNDRY_PATHS+=("$FOUNDRY_DIR/bin"); fi
    if [[ -n "${HOME:-}" ]]; then FOUNDRY_PATHS+=("$HOME/.foundry/bin"); fi
    if [[ -n "${USERPROFILE:-}" ]] && command -v cygpath >/dev/null 2>&1; then
        WINDOWS_PROFILE="$(cygpath -u "$USERPROFILE")"
        FOUNDRY_PATHS+=("$WINDOWS_PROFILE/.foundry/bin")
    fi
    for FOUNDRY_BIN in "${FOUNDRY_PATHS[@]}"; do
        if [[ -d "$FOUNDRY_BIN" ]]; then export PATH="$PATH:$FOUNDRY_BIN"; fi
    done
fi
if ! command -v forge >/dev/null 2>&1 || ! command -v cast >/dev/null 2>&1; then
    echo "Error: could not find Foundry (forge and cast). Add its bin directory to PATH or set FOUNDRY_DIR." >&2
    exit 1
fi

require_address() {
    local name=$1 value=${!1:-}
    if [[ ! "$value" =~ ^0x[0-9a-fA-F]{40}$ || "$value" == "0x0000000000000000000000000000000000000000" ]]; then
        echo "Error: $name must be a nonzero contract or signer address." >&2
        exit 1
    fi
}

# Use the original constructor signer, even if the on-chain signer has rotated.
ATLAS_SIGNER="${ATLAS_SIGNER:-0x59eD4701224fD9e2a85Ef2946c2ab828C1dDC600}"
ADDRESS_VARS=(USDC_ADDRESS ATLAS_PPUSDC_ADDRESS PERPDEX_ATLAS_ADDRESS ATLAS_OPUSDC_ADDRESS
    OPTION_AMM_ATLAS_ADDRESS ATLAS_PMUSDC_ADDRESS PREDICTION_MARKET_AMM_ATLAS_ADDRESS)
for ADDRESS_VAR in "${ADDRESS_VARS[@]}" ATLAS_SIGNER; do require_address "$ADDRESS_VAR"; done

ACTUAL_CHAIN_ID="$(cast chain-id --rpc-url "$RPC_URL")"
if [[ "$ACTUAL_CHAIN_ID" != "$CHAIN_ID" ]]; then
    echo "Error: RPC chain ID is $ACTUAL_CHAIN_ID but CHAIN_ID is $CHAIN_ID." >&2
    exit 1
fi

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

VERIFIER=etherscan
VERIFIER_URL="https://api.etherscan.io/v2/api?chainid=$CHAIN_ID"
VERIFIER_API_KEY="${ETHERSCAN_API_KEY:-}"
VERIFIER_API_KEY_ENCODED=""
case "$CHAIN_ID" in
    143|10143)
        VERIFIER=sourcify
        VERIFIER_URL="${MONAD_SOURCIFY_URL:-https://sourcify-api-monad.blockvision.org/}"
        VERIFIER_API_KEY=""
        ;;
    4663|46630)
        VERIFIER=sourcify
        VERIFIER_URL="https://sourcify.dev/server/"
        VERIFIER_API_KEY=""
        if [[ "$CHAIN_ID" == "4663" && -n "${BLOCKSCOUT_API_KEY:-}" ]]; then
            VERIFIER=blockscout
            VERIFIER_API_KEY="$BLOCKSCOUT_API_KEY"
            VERIFIER_API_KEY_ENCODED="$(url_encode "$VERIFIER_API_KEY")"
            VERIFIER_URL="https://api.blockscout.com/v2/api?chain_id=$CHAIN_ID&apikey=$VERIFIER_API_KEY_ENCODED"
        fi
        ;;
esac
if [[ "$VERIFIER" == etherscan && -z "$VERIFIER_API_KEY" ]]; then
    echo "Error: ETHERSCAN_API_KEY is required for Etherscan API V2 on chain $CHAIN_ID." >&2
    exit 1
fi

# Complete preflight before submitting anything to an explorer.
for ADDRESS_VAR in "${ADDRESS_VARS[@]}"; do
    CODE="$(cast code "${!ADDRESS_VAR}" --rpc-url "$RPC_URL")"
    if [[ -z "$CODE" || "$CODE" == "0x" ]]; then
        echo "Error: no contract code at $ADDRESS_VAR (${!ADDRESS_VAR})." >&2
        exit 1
    fi
done
assert_link() {
    local vault=$1 getter=$2 expected=$3 actual
    actual="$(cast call "$vault" "$getter" --rpc-url "$RPC_URL")"
    if [[ "${actual,,}" != "${expected,,}" ]]; then
        echo "Error: $getter on $vault does not match the address configured in $ENV_FILE." >&2
        exit 1
    fi
}
for VAULT in "$PERPDEX_ATLAS_ADDRESS" "$OPTION_AMM_ATLAS_ADDRESS" "$PREDICTION_MARKET_AMM_ATLAS_ADDRESS"; do
    assert_link "$VAULT" 'usdc()(address)' "$USDC_ADDRESS"
done
assert_link "$PERPDEX_ATLAS_ADDRESS" 'ppUSDC()(address)' "$ATLAS_PPUSDC_ADDRESS"
assert_link "$OPTION_AMM_ATLAS_ADDRESS" 'opUSDC()(address)' "$ATLAS_OPUSDC_ADDRESS"
assert_link "$PREDICTION_MARKET_AMM_ATLAS_ADDRESS" 'shareToken()(address)' "$ATLAS_PMUSDC_ADDRESS"

PERP_MAX_AGE="$(cast call "$PERPDEX_ATLAS_ADDRESS" 'maxPriceAge()(uint256)' --rpc-url "$RPC_URL")"
PREDICTION_FEE="$(cast call "$PREDICTION_MARKET_AMM_ATLAS_ADDRESS" 'feeBps()(uint256)' --rpc-url "$RPC_URL")"
# Cast can annotate large uints with a scientific-notation suffix.
PERP_MAX_AGE="${PERP_MAX_AGE%% *}"
PREDICTION_FEE="${PREDICTION_FEE%% *}"
PERP_ARGS="$(cast abi-encode 'constructor(address,address,address,uint256)' \
    "$USDC_ADDRESS" "$ATLAS_PPUSDC_ADDRESS" "$ATLAS_SIGNER" "$PERP_MAX_AGE")"
OPTION_ARGS="$(cast abi-encode 'constructor(address,address,address)' \
    "$USDC_ADDRESS" "$ATLAS_SIGNER" "$ATLAS_OPUSDC_ADDRESS")"
PREDICTION_ARGS="$(cast abi-encode 'constructor(address,address,uint256)' \
    "$USDC_ADDRESS" "$ATLAS_SIGNER" "$PREDICTION_FEE")"
PMUSDC_ARGS="$(cast abi-encode 'constructor(address)' "$PREDICTION_MARKET_AMM_ATLAS_ADDRESS")"

redact_output() {
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ -n "$VERIFIER_API_KEY" ]]; then line=${line//"$VERIFIER_API_KEY"/[redacted]}; fi
        if [[ -n "$VERIFIER_API_KEY_ENCODED" ]]; then line=${line//"$VERIFIER_API_KEY_ENCODED"/[redacted]}; fi
        printf '%s\n' "$line"
    done
}

SUCCESS_COUNT=0
FAILURE_COUNT=0
verify_contract() {
    local address=$1 contract=$2 constructor_args=${3:-} verification_exit=0
    local args=(verify-contract --rpc-url "$RPC_URL" --chain "$CHAIN_ID"
        --compiler-version 0.8.20 --num-of-optimizations 1 --via-ir
        --verifier "$VERIFIER" --verifier-url "$VERIFIER_URL")
    if [[ "$VERIFIER" != sourcify || "$CHAIN_ID" == 4663 || "$CHAIN_ID" == 46630 ]]; then
        args+=(--watch)
    fi
    if [[ "$VERIFIER" != sourcify ]]; then args+=(--etherscan-api-key "$VERIFIER_API_KEY"); fi
    if [[ "$VERIFIER" == blockscout ]]; then args+=(--skip-is-verified-check); fi
    if [[ -n "$constructor_args" ]]; then args+=(--constructor-args "$constructor_args"); fi
    args+=("$address" "$contract")

    echo "Verifying $contract at $address ($VERIFIER)..."
    if [[ "$VERIFIER" == sourcify ]]; then
        # Prevent an unrelated dotenv Etherscan key from changing the provider.
        ETHERSCAN_API_KEY= VERIFIER_API_KEY= FOUNDRY_PROFILE=default forge "${args[@]}" 2>&1 |
            redact_output || verification_exit=$?
    else
        FOUNDRY_PROFILE=default forge "${args[@]}" 2>&1 | redact_output || verification_exit=$?
    fi
    if (( verification_exit == 0 )); then
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        echo "Failed to verify $contract." >&2
        FAILURE_COUNT=$((FAILURE_COUNT + 1))
    fi
}

echo "Atlas verification: chain $CHAIN_ID, provider $VERIFIER"
verify_contract "$ATLAS_PPUSDC_ADDRESS" src/ppUSDC.sol:ppUSDC
verify_contract "$ATLAS_OPUSDC_ADDRESS" src/opUSDC.sol:opUSDC
verify_contract "$PERPDEX_ATLAS_ADDRESS" src/PerpDexAtlas.sol:PerpDexAtlas "$PERP_ARGS"
verify_contract "$OPTION_AMM_ATLAS_ADDRESS" src/OptionAMMAtlas.sol:OptionAMMAtlas "$OPTION_ARGS"
verify_contract "$PREDICTION_MARKET_AMM_ATLAS_ADDRESS" src/PredictionMarketAMMAtlas.sol:PredictionMarketAMMAtlas "$PREDICTION_ARGS"
verify_contract "$ATLAS_PMUSDC_ADDRESS" src/pmUSDC.sol:pmUSDC "$PMUSDC_ARGS"

echo "Verification complete: $SUCCESS_COUNT succeeded, $FAILURE_COUNT failed."
if [[ "$VERIFIER" == sourcify && ( "$CHAIN_ID" == 4663 || "$CHAIN_ID" == 46630 ) ]]; then
    echo "Sourcify verification does not confirm a verified badge on Blockscout; a separate import may be needed."
fi
if (( FAILURE_COUNT > 0 )); then exit 1; fi

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../.."

usage() {
    echo "Usage: bash script/deploy/deploy-prediction-atlas.sh [environment-file] [--dry-run|--broadcast] [--resume|--start-fresh]"
    echo "Default: simulate PredictionMarketAMMAtlas and its fresh pmUSDC token using existing USDC."
    echo "  --broadcast    Send the prediction deployment transaction."
    echo "  --resume       Resume a saved broadcast; requires --broadcast."
    echo "  --start-fresh  Archive an unfinished broadcast and deploy anew; requires --broadcast."
}

ENV_FILE=".env"
if [[ "$#" -gt 0 && "$1" != -* ]]; then
    ENV_FILE="$1"
    shift
fi
RUN_MODE=""
RECOVERY_MODE=""
for ARG in "$@"; do
    case "$ARG" in
        -h|--help) usage; exit 0 ;;
        --dry-run|--broadcast)
            if [[ -n "$RUN_MODE" ]]; then
                echo "Error: choose only one of --dry-run or --broadcast." >&2
                exit 1
            fi
            RUN_MODE="$ARG"
            ;;
        --resume|--start-fresh)
            if [[ -n "$RECOVERY_MODE" ]]; then
                echo "Error: choose only one recovery mode." >&2
                exit 1
            fi
            RECOVERY_MODE="$ARG"
            ;;
        *) echo "Unknown option: $ARG" >&2; usage >&2; exit 1 ;;
    esac
done
if [[ -n "$RECOVERY_MODE" && "$RUN_MODE" != --broadcast ]]; then
    echo "Error: recovery modes require --broadcast." >&2
    exit 1
fi
if [[ ! -f "$ENV_FILE" ]]; then
    echo "Error: environment file not found: $ENV_FILE" >&2
    exit 1
fi
set -a
# Accept Windows CRLF environment files.
# shellcheck disable=SC1090
source <(tr -d '\r' < "$ENV_FILE")
set +a
for REQUIRED_VAR in PRIVATE_KEY RPC_URL CHAIN_ID USDC_ADDRESS; do
    if [[ -z "${!REQUIRED_VAR:-}" ]]; then
        echo "Error: $REQUIRED_VAR is not set in $ENV_FILE." >&2
        exit 1
    fi
done
export ATLAS_SIGNER="${ATLAS_SIGNER:-0x59eD4701224fD9e2a85Ef2946c2ab828C1dDC600}"
export PREDICTION_FEE_BPS="${PREDICTION_FEE_BPS:-300}"
export FOUNDRY_PROFILE=default

# Git Bash may not inherit Foundry's PATH entry from PowerShell.
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
ACTUAL_CHAIN_ID="$(cast chain-id --rpc-url "$RPC_URL")"
if [[ "$ACTUAL_CHAIN_ID" != "$CHAIN_ID" ]]; then
    echo "Error: RPC chain ID is $ACTUAL_CHAIN_ID but CHAIN_ID is $CHAIN_ID." >&2
    exit 1
fi

echo "Atlas prediction deployment: PredictionMarketAMMAtlas and its fresh pmUSDC token"
echo "Chain ID: $CHAIN_ID"
echo "Existing USDC: $USDC_ADDRESS"
echo "Atlas signer: $ATLAS_SIGNER"
echo "Prediction fee: $PREDICTION_FEE_BPS bps"
FORGE_ARGS=(script script/DeployPredictionMarketAMMAtlas.s.sol:DeployPredictionMarketAMMAtlas --rpc-url "$RPC_URL" -vvv)
if [[ "$RUN_MODE" == --broadcast ]]; then
    FORGE_ARGS+=(--broadcast --slow)
else
    echo "Simulation only. Add --broadcast to deploy."
fi
if [[ -n "$RECOVERY_MODE" ]]; then FORGE_ARGS+=("$RECOVERY_MODE"); fi
if [[ "$RECOVERY_MODE" == --resume ]]; then
    # Resume skips run(), so provide the signer for the saved transaction.
    FORGE_ARGS+=(--private-key "$PRIVATE_KEY")
fi
if [[ "$CHAIN_ID" == 56 ]]; then FORGE_ARGS+=(--legacy); fi

if ! forge "${FORGE_ARGS[@]}"; then
    echo "Atlas prediction deployment failed. Inspect broadcast/DeployPredictionMarketAMMAtlas.s.sol/$CHAIN_ID/ before retrying." >&2
    echo "Check confirmed receipts and the deployer's nonce before using --broadcast --resume." >&2
    exit 1
fi
if [[ "$RUN_MODE" == --broadcast ]]; then
    echo "Deployment confirmed. Save PREDICTION_MARKET_AMM_ATLAS_ADDRESS from broadcast/DeployPredictionMarketAMMAtlas.s.sol/$CHAIN_ID/run-latest.json."
    echo "Read shareToken() on the confirmed prediction vault and save it as ATLAS_PMUSDC_ADDRESS."
    echo "On resume, use saved receipts rather than addresses from another simulation."
    echo "After saving the vault address, seed pairs with: bash script/deploy/seed-atlas-pairs.sh $ENV_FILE prediction --broadcast"
    echo "Next: authorize the worker with authorizeBackend(worker, true) and deposit USDC liquidity."
fi

#!/usr/bin/env bash
set -euo pipefail

# Usage: bash script/deploy/seed-initial-pairs.sh [environment-file] [both|perp|oneclick|prediction|options] [--dry-run]
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../.."

if [[ "${1:-}" == "--help" || "$#" -gt 3 ]]; then
    echo "Usage: bash script/deploy/seed-initial-pairs.sh [environment-file] [both|perp|oneclick|prediction|options] [--dry-run]"
    exit 0
fi

ENV_FILE="${1:-.env}"
TARGET="${2:-both}"
MODE="${3:-}"
case "$TARGET" in
    both) ENTRYPOINT=ConfigureInitialPairs ;;
    perp) ENTRYPOINT=ConfigurePerpDexPairs ;;
    oneclick) ENTRYPOINT=ConfigureOneClickPairs ;;
    prediction) ENTRYPOINT=ConfigurePredictionPairs ;;
    options) ENTRYPOINT=ConfigureOptionsPairs ;;
    *) echo "Error: target must be both, perp, oneclick, prediction, or options." >&2; exit 1 ;;
esac
if [[ -n "$MODE" && "$MODE" != "--dry-run" ]]; then
    echo "Error: third argument must be --dry-run or omitted to broadcast." >&2
    exit 1
fi
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
if [[ "$TARGET" == "both" || "$TARGET" == "perp" ]]; then
    : "${PERPDEX_ADDRESS:?Error: PERPDEX_ADDRESS is required}"
fi
if [[ "$TARGET" == "both" || "$TARGET" == "oneclick" ]]; then
    : "${ONECLICK_PERPDEX_ADDRESS:?Error: ONECLICK_PERPDEX_ADDRESS is required}"
fi

if [[ "$TARGET" == "prediction" ]]; then
    : "${PREDICTION_MARKET_AMM_ADDRESS:?Error: PREDICTION_MARKET_AMM_ADDRESS is required}"
fi
if [[ "$TARGET" == "options" ]]; then
    : "${OPTIONS_AMM_ADDRESS:?Error: OPTIONS_AMM_ADDRESS is required}"
fi

ACTUAL_CHAIN_ID="$(cast chain-id --rpc-url "$RPC_URL")"
if [[ "$ACTUAL_CHAIN_ID" != "$CHAIN_ID" ]]; then
    echo "Error: RPC returned chain ID $ACTUAL_CHAIN_ID; expected CHAIN_ID $CHAIN_ID." >&2
    exit 1
fi

FORGE_ARGS=(
    script "script/ConfigureInitialPairs.s.sol:$ENTRYPOINT"
    --rpc-url "$RPC_URL"
    --slow
    -vvvv
)
if [[ "$CHAIN_ID" == "56" ]]; then
    FORGE_ARGS+=(--legacy)
fi
if [[ "$MODE" == "--dry-run" ]]; then
    echo "Simulating initial pair configuration for $TARGET on chain $CHAIN_ID."
else
    echo "Broadcasting initial pair configuration for $TARGET on chain $CHAIN_ID."
    FORGE_ARGS+=(--broadcast)
fi

forge "${FORGE_ARGS[@]}"

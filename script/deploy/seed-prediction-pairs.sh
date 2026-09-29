#!/usr/bin/env bash
set -euo pipefail

# Seed only BTC_USD, ETH_USD, and SOL_USD on the prediction market AMM.
# Environment file paths are resolved relative to the repository root.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    echo "Usage: bash script/deploy/seed-prediction-pairs.sh [environment-file] [--dry-run]"
}

if [[ "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

ENV_FILE=".env"
if [[ "$#" -gt 0 && "$1" != --* ]]; then
    ENV_FILE="$1"
    shift
fi

if [[ "$#" -gt 1 || ( "$#" -eq 1 && "$1" != "--dry-run" ) ]]; then
    usage >&2
    exit 1
fi

exec bash "$SCRIPT_DIR/seed-initial-pairs.sh" "$ENV_FILE" prediction "$@"

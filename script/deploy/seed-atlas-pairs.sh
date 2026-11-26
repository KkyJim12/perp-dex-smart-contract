#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../.."
usage() {
    echo "Usage: bash script/deploy/seed-atlas-pairs.sh [environment-file] [all|perp|option|prediction] [--dry-run|--broadcast] [--resume]"
    echo "Default: simulate all three Atlas vaults; .env can override Atlas feed IDs."
    echo "Perp/prediction seed 8 crypto and 7 stocks using the user's private feeds; options seed BTC/ETH/SOL."
    echo "Use --broadcast to send transactions; use --broadcast --resume for an interrupted saved broadcast."
}
ENV_FILE=.env
TARGET=all
if [[ "$#" -gt 0 && "$1" != -* && "$1" != all && "$1" != perp && "$1" != option && "$1" != prediction ]]; then
    ENV_FILE="$1"
    shift
fi
if [[ "$#" -gt 0 && "$1" != -* ]]; then
    TARGET="$1"
    shift
fi
case "$TARGET" in
    all|perp|option|prediction) ;;
    *) echo "Error: target must be all, perp, option, or prediction." >&2; exit 1 ;;
esac
MODE=""
RESUME=false
for ARG in "$@"; do
    case "$ARG" in
        -h|--help) usage; exit 0 ;;
        --dry-run|--broadcast)
            if [[ -n "$MODE" ]]; then echo "Error: choose one run mode." >&2; exit 1; fi
            MODE="$ARG"
            ;;
        --resume) RESUME=true ;;
        *) echo "Unknown option: $ARG" >&2; usage >&2; exit 1 ;;
    esac
done
if [[ "$RESUME" == true && "$MODE" != --broadcast ]]; then
    echo "Error: --resume requires --broadcast." >&2
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
export ATLAS_SEED_TARGET="$TARGET"
for REQUIRED_VAR in PRIVATE_KEY RPC_URL CHAIN_ID; do
    if [[ -z "${!REQUIRED_VAR:-}" ]]; then echo "Error: $REQUIRED_VAR is required in $ENV_FILE." >&2; exit 1; fi
done

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
FORGE_ARGS=(script script/ConfigureAtlasPairs.s.sol:ConfigureAtlasPairs --rpc-url "$RPC_URL" --slow -vvv)
if [[ "$MODE" == --broadcast ]]; then
    FORGE_ARGS+=(--broadcast)
    echo "Seeding $TARGET Atlas pairs on chain $CHAIN_ID."
else
    echo "Simulating $TARGET Atlas pair seeds on chain $CHAIN_ID; add --broadcast to send transactions."
fi
if [[ "$RESUME" == true ]]; then FORGE_ARGS+=(--resume --private-key "$PRIVATE_KEY"); fi
if [[ "$CHAIN_ID" == 56 ]]; then FORGE_ARGS+=(--legacy); fi
if ! forge "${FORGE_ARGS[@]}"; then
    echo "Atlas pair seeding failed. Inspect broadcast/ConfigureAtlasPairs.s.sol/$CHAIN_ID/ before retrying." >&2
    echo "For partial broadcasts, check receipts and nonces, then use the same environment/target with --broadcast --resume." >&2
    exit 1
fi

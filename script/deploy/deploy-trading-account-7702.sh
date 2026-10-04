#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../.."

usage() {
    echo "Usage: bash script/deploy/deploy-trading-account-7702.sh [environment-file] [--dry-run] [--yes]"
    echo "Environment file defaults to .env; relative paths resolve from the repository root."
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

DRY_RUN=false
CONFIRMED=false
for ARG in "$@"; do
    case "$ARG" in
        --dry-run) DRY_RUN=true ;;
        --yes) CONFIRMED=true ;;
        *) usage >&2; exit 1 ;;
    esac
done

if [[ ! -f "$ENV_FILE" ]]; then
    echo "Error: environment file not found: $ENV_FILE" >&2
    exit 1
fi

# Accept shell-compatible environment files with Windows or Unix line endings.
set -a
# shellcheck disable=SC1090
source <(tr -d '\r' < "$ENV_FILE")
set +a

for REQUIRED_VAR in PRIVATE_KEY RPC_URL CHAIN_ID; do
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

DEPLOYER_ADDRESS="$(cast wallet address --private-key "$PRIVATE_KEY")"
DEPLOYER_BALANCE="$(cast balance "$DEPLOYER_ADDRESS" --rpc-url "$RPC_URL")"
if [[ "$DEPLOYER_BALANCE" == "0" ]]; then
    echo "Error: deployer has no native-token balance for gas." >&2
    exit 1
fi

echo "TradingAccount7702 deployment"
echo "Chain ID: $CHAIN_ID"
echo "Deployer: $DEPLOYER_ADDRESS"
echo "Native balance (wei): $DEPLOYER_BALANCE"

FORGE_ARGS=(
    script script/DeployTradingAccount7702.s.sol:DeployTradingAccount7702
    --rpc-url "$RPC_URL"
    -vvv
)

if [[ "$DRY_RUN" == true ]]; then
    echo "Simulating deployment."
else
    if [[ "$CONFIRMED" != true ]]; then
        read -r -p "Deploy TradingAccount7702 to chain $CHAIN_ID? (y/N) " REPLY
        if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
            echo "Deployment cancelled."
            exit 0
        fi
    fi
    FORGE_ARGS+=(--broadcast --slow)
fi

if [[ "$CHAIN_ID" == "56" ]]; then
    FORGE_ARGS+=(--legacy)
fi

# Keep the existing Solidity 0.8.20 deployment settings even if the caller
# previously selected the Prague test profile.
FOUNDRY_PROFILE=default forge "${FORGE_ARGS[@]}"

if [[ "$DRY_RUN" == true ]]; then
    echo "Simulation completed."
else
    echo "Deployment completed. Save the printed implementation address as TRADING_ACCOUNT7702_ADDRESS."
    echo "See docs/eip7702.md for verification and wallet delegation."
fi

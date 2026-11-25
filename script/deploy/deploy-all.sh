#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../.."

# Recovery must be explicit: resuming preserves the saved transaction plan,
# while starting fresh archives it and creates a new deployment.
DEPLOYMENT_MODE=""
case "${1:-}" in
    "") ;;
    --resume|--start-fresh) DEPLOYMENT_MODE="$1"; shift ;;
    -h|--help)
        echo "Usage: bash script/deploy/deploy-all.sh [--resume|--start-fresh]"
        echo "  --resume       Continue the saved deployment without simulating again."
        echo "  --start-fresh  Archive the saved deployment and deploy new contracts."
        exit 0
        ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
esac
if [ "$#" -ne 0 ]; then
    echo "Use only one deployment mode: --resume or --start-fresh." >&2
    exit 1
fi

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${BLUE}====================================${NC}"
echo -e "${BLUE}Complete PerpDex Deployment Script${NC}"
echo -e "${BLUE}====================================${NC}"
echo ""

# Load environment variables
if [ -f .env ]; then
    set -a
    # shellcheck disable=SC1091
    source <(tr -d '\r' < .env)
    set +a
    echo -e "${GREEN}✓ Loaded .env file${NC}"
else
    echo -e "${RED}✗ .env file not found${NC}"
    exit 1
fi

# Check required environment variables
if [ -z "$PRIVATE_KEY" ]; then
    echo -e "${RED}✗ PRIVATE_KEY not set in .env${NC}"
    exit 1
fi

if [ -z "$RPC_URL" ]; then
    echo -e "${RED}✗ RPC_URL not set in .env${NC}"
    exit 1
fi

if [ -z "$PYTH_ADDRESS" ]; then
    echo -e "${RED}✗ PYTH_ADDRESS not set in .env${NC}"
    exit 1
fi

if ! command -v cast >/dev/null 2>&1; then
    echo -e "${RED}âœ— cast is not installed or not on PATH${NC}"
    exit 1
fi

if ! command -v forge >/dev/null 2>&1; then
    echo -e "${RED}forge is not installed or not on PATH${NC}" >&2
    exit 1
fi

if [ -z "${CHAIN_ID:-}" ]; then
    echo -e "${RED}CHAIN_ID not set in .env${NC}"
    exit 1
fi

if ! ACTUAL_CHAIN_ID="$(cast chain-id --rpc-url "$RPC_URL")"; then
    echo -e "${RED}Could not read chain ID from RPC${NC}" >&2
    exit 1
fi
if [ "$ACTUAL_CHAIN_ID" != "$CHAIN_ID" ]; then
    echo -e "${RED}RPC returned chain ID ${ACTUAL_CHAIN_ID}; expected CHAIN_ID ${CHAIN_ID}${NC}"
    exit 1
fi

echo -e "${GREEN}✓ All required environment variables set${NC}"
echo ""

# Display deployment info
echo -e "${BLUE}Network: ${NETWORK_NAME:-Chain ${CHAIN_ID}}${NC}"
echo -e "${BLUE}Chain ID: ${CHAIN_ID}${NC}"
echo -e "${BLUE}RPC URL: $RPC_URL${NC}"
echo ""

# Ask for confirmation
if [ "$DEPLOYMENT_MODE" = "--resume" ]; then
    echo -e "${YELLOW}Resuming the saved deployment; its addresses and transactions will be reused.${NC}"
    echo "The saved transaction nonces must still match the deployer's on-chain nonce."
else
    if [ "$DEPLOYMENT_MODE" = "--start-fresh" ]; then
        echo -e "${YELLOW}Starting fresh: the old broadcast will be archived and new contracts deployed.${NC}"
        echo "Previously deployed contracts remain on-chain. New addresses must be saved after success."
    fi
    echo -e "${YELLOW}This will deploy:${NC}"
    echo "  1. MockUSDC (or use existing USDC)"
    echo "  2. ppUSDC (Main PerpDex LP Token)"
    echo "  3. Main PerpDex"
    echo "  4. ocUSDC (OneClick PerpDex LP Token)"
    echo "  5. OneClick PerpDex"
    echo "  6. opUSDC (Option AMM LP Token)"
    echo "  7. Option AMM"
    echo "  8. Prediction Market AMM and its pmUSDC LP Token"
    echo "     Prediction edge: ${PREDICTION_FEE_BPS:-300} bps; BTC/ETH/SOL feeds"
fi
echo ""
read -p "Continue with deployment? (y/n) " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${RED}Deployment cancelled${NC}"
    exit 1
fi

echo ""
echo -e "${BLUE}====================================${NC}"
echo -e "${BLUE}Starting Deployment...${NC}"
echo -e "${BLUE}====================================${NC}"
echo ""

# Run deployment
FORGE_ARGS=(script script/DeployAll.s.sol --rpc-url "$RPC_URL" --broadcast --slow -vvv)
if [ -n "$DEPLOYMENT_MODE" ]; then
    FORGE_ARGS+=("$DEPLOYMENT_MODE")
fi
if [ "$DEPLOYMENT_MODE" = "--resume" ]; then
    # Resume skips run(), so vm.startBroadcast(PRIVATE_KEY) cannot load the signer.
    FORGE_ARGS+=(--private-key "$PRIVATE_KEY")
fi
forge "${FORGE_ARGS[@]}"

# Check if deployment was successful
if [ $? -eq 0 ]; then
    echo ""
    echo -e "${GREEN}====================================${NC}"
    echo -e "${GREEN}✓ Deployment Successful!${NC}"
    echo -e "${GREEN}====================================${NC}"
    echo ""
    echo -e "${YELLOW}Next steps:${NC}"
    echo "1. Save addresses from confirmed receipts in broadcast/DeployAll.s.sol/${CHAIN_ID}/run-latest.json to .env"
    echo "   For pmUSDC, read shareToken() from the confirmed PredictionMarketAMM address."
    echo "2. Authorize backend address for OneClick PerpDex"
    echo "3. Verify contracts: bash script/deploy/verify-all.sh"
    echo "4. Create option markets and prediction rounds separately"
    echo ""
else
    echo ""
    echo -e "${RED}====================================${NC}"
    echo -e "${RED}✗ Deployment Failed${NC}"
    echo -e "${RED}====================================${NC}"
    echo ""
    echo "Check the error messages above for details"
    echo "For an unfinished broadcast, inspect its receipts and the deployer's nonce, then use:"
    echo "  bash script/deploy/deploy-all.sh --resume"
    echo "If recovery is impossible and a new deployment is intended, use:"
    echo "  bash script/deploy/deploy-all.sh --start-fresh"
    echo "Do not save addresses printed by a failed simulation as deployed addresses."
    exit 1
fi

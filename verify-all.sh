#!/bin/bash

# Monad Contract Verification Script
# Verifies all deployed contracts using Sourcify

set -e  # Exit on error

# Load environment variables
source .env

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Sourcify verifier URL (MUST end with /)
VERIFIER_URL="https://sourcify-api-monad.blockvision.org/"
RPC_URL="${RPC_URL}"
CHAIN_ID="${CHAIN_ID}"

echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}Monad Contract Verification${NC}"
echo -e "${YELLOW}========================================${NC}"
echo ""

# Function to verify a contract
verify_contract() {
    local address=$1
    local contract_path=$2
    local contract_name=$3
    local constructor_args=$4
    
    echo -e "${YELLOW}Verifying ${contract_name}...${NC}"
    echo "Address: ${address}"
    echo "Contract: ${contract_path}:${contract_name}"
    
    if [ -z "$constructor_args" ]; then
        forge verify-contract \
            --rpc-url "${RPC_URL}" \
            --verifier sourcify \
            --verifier-url "${VERIFIER_URL}" \
            --chain-id "${CHAIN_ID}" \
            "${address}" \
            "${contract_path}:${contract_name}"
    else
        forge verify-contract \
            --rpc-url "${RPC_URL}" \
            --verifier sourcify \
            --verifier-url "${VERIFIER_URL}" \
            --chain-id "${CHAIN_ID}" \
            --constructor-args "${constructor_args}" \
            "${address}" \
            "${contract_path}:${contract_name}"
    fi
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ ${contract_name} verified successfully!${NC}"
    else
        echo -e "${RED}✗ ${contract_name} verification failed!${NC}"
    fi
    echo ""
}

# 1. Verify MockUSDC (if deployed)
if [ ! -z "$USDC_ADDRESS" ]; then
    verify_contract \
        "$USDC_ADDRESS" \
        "src/MockUSDC.sol" \
        "MockUSDC" \
        ""
fi

# 2. Verify ppUSDC (Main PerpDex LP Token)
if [ ! -z "$PPUSDC_ADDRESS" ]; then
    verify_contract \
        "$PPUSDC_ADDRESS" \
        "src/ppUSDC.sol" \
        "ppUSDC" \
        ""
fi

# 3. Verify ocUSDC (OneClick PerpDex LP Token)
if [ ! -z "$OCUSDC_ADDRESS" ]; then
    verify_contract \
        "$OCUSDC_ADDRESS" \
        "src/ocUSDC.sol" \
        "ocUSDC" \
        ""
fi

# 4. Verify Main PerpDex
if [ ! -z "$PERPDEX_ADDRESS" ]; then
    # Constructor args: address _pyth, address _usdc, address _ppUSDC
    CONSTRUCTOR_ARGS=$(cast abi-encode "constructor(address,address,address)" "$PYTH_ADDRESS" "$USDC_ADDRESS" "$PPUSDC_ADDRESS")
    
    verify_contract \
        "$PERPDEX_ADDRESS" \
        "src/PerpDex.sol" \
        "PerpDEX" \
        "$CONSTRUCTOR_ARGS"
fi

# 5. Verify OneClickPerpDex
if [ ! -z "$ONECLICK_PERPDEX_ADDRESS" ]; then
    # Constructor args: address _usdc, address _ocUSDC
    CONSTRUCTOR_ARGS=$(cast abi-encode "constructor(address,address)" "$USDC_ADDRESS" "$OCUSDC_ADDRESS")
    
    verify_contract \
        "$ONECLICK_PERPDEX_ADDRESS" \
        "src/OneClickPerpDex.sol" \
        "OneClickPerpDex" \
        "$CONSTRUCTOR_ARGS"
fi

echo -e "${YELLOW}========================================${NC}"
echo -e "${GREEN}Verification Complete!${NC}"
echo -e "${YELLOW}========================================${NC}"
echo ""
echo "Check verification status at:"
echo "https://explorer.monad.xyz/"
echo ""

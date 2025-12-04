#### BASE DEPLOY

forge script script/MockUSDT.s.sol \
 --rpc-url $RPC_URL \
 --private-key $PRIVATE_KEY \
 --chain-id $CHAIN_ID \
 --broadcast

forge script script/PerpDex.s.sol:PerpDexScript \
 --rpc-url $RPC_URL \
 --private-key $PRIVATE_KEY \
 --chain-id $CHAIN_ID \
 --broadcast

#### FLATTEN

forge flatten src/MockUSDT.sol > flatten/MockUSDT_flat.sol
forge flatten src/PerpDex.sol > flatten/PerpDex_flat.sol

#### VERIFY ON BASE

forge verify-contract \
 --verifier etherscan \
 --etherscan-api-key $BLOCK_EXPLORER_API_KEY \
 --chain-id $CHAIN_ID \
 0x1f75920BcFB8da23734f2963e241cAE3BbdD283B \
 src/MockUSDT.sol:MockUSDT \
 --watch

forge verify-contract \
 --verifier etherscan \
 --etherscan-api-key $BLOCK_EXPLORER_API_KEY \
 --chain-id $CHAIN_ID \
 0xA00F36447dbC45D201429eD2C836Ea6a53D11b11 \
 src/PerpDex.sol:PerpDEX \
 --watch

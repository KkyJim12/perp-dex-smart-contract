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
 0x97509e1E76416d89DCe60605af813c935d893Dad \
 src/PerpDex.sol:PerpDEX \
 --watch

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
 0xDE303B4289Eae7D9d5a0586c2c7dc75A56B978C7 \
 src/PerpDex.sol:PerpDEX \
 --watch

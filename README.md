Deploy Command (Monad)
forge script script/MockUSDT.s.sol --rpc-url $RPC_URL --private-key $PRIVATE_KEY --chain-id $CHAIN_ID  --broadcast
forge script script/PerpDex.s.sol:PerpDexScript --rpc-url $RPC_URL --private-key $PRIVATE_KEY --chain-id $CHAIN_ID --broadcast

Flatten Command 
forge flatten src/MockUSDT.sol > flatten/FlattenedMockUSDT.sol
forge flatten src/PerpDex.sol > flatten/FlattenedPerpDex.sol

Verify Command (Monad)
forge verify-contract --chain-id $CHAIN_ID $PERPDEX_CONTRACT_ADDRESS src/PerpDex.sol:PerpDex --flatten --etherscan-api-key $ETHER_SCAN_API_KEY --watch

forge verify-contract \
  --rpc-url https://testnet-rpc.monad.xyz \
  --verifier sourcify \
  --verifier-url 'https://sourcify-api-monad.blockvision.org' \
  0x2953A88b1d189d28dC53F6f364eE074FCB6F5a5A \
  src/PerpDex.sol:PerpDEX
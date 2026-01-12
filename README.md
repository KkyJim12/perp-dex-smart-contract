#### MONAD DEPLOY

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

#### VERIFY ON MONAD

forge verify-contract \
  --rpc-url https://rpc.monad.xyz \
  --verifier sourcify \
  --verifier-url 'https://sourcify-api-monad.blockvision.org/' \
  --chain-id 143 \
  0x8CFf46281C0C3eeA94Dc43f75E710E6a4764c101 \
  src/MockUSDT.sol:MockUSDT

forge verify-contract \
  --rpc-url https://rpc.monad.xyz \
  --verifier sourcify \
  --verifier-url 'https://sourcify-api-monad.blockvision.org/' \
  --chain-id 143 \
  0x83C16f2F40016eBcF076abdC07B21EF95312A74E \
  src/PerpDex.sol:PerpDEX


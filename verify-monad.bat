@echo off
echo ======================================
echo Monad Mainnet - NativeStaking Verification
echo ======================================
echo.

if not exist .env.monad (
    echo Error: .env.monad not found
    exit /b 1
)

for /f "tokens=*" %%a in ('type .env.monad ^| findstr /v "^#"') do set %%a

if "%NATIVE_STAKING_ADDRESS%"=="" (
    echo Error: NATIVE_STAKING_ADDRESS not set in .env.monad
    exit /b 1
)

echo Contract: %NATIVE_STAKING_ADDRESS%
echo.

echo 1. Verifying on Sourcify (MonadVision)...
forge verify-contract %NATIVE_STAKING_ADDRESS% src/NativeStaking.sol:NativeStaking --chain-id 143 --verifier sourcify --verifier-url https://sourcify-api-monad.blockvision.org --watch
if errorlevel 1 echo Warning: Sourcify verification failed (may already be verified)
echo.

if not "%ETHERSCAN_API_KEY%"=="" (
    echo 2. Verifying on Etherscan (MonadScan)...
    forge verify-contract %NATIVE_STAKING_ADDRESS% src/NativeStaking.sol:NativeStaking --chain-id 143 --verifier etherscan --verifier-url "https://api.etherscan.io/v2/api?chainid=143" --etherscan-api-key %ETHERSCAN_API_KEY% --watch
    if errorlevel 1 echo Warning: Etherscan verification failed (may already be verified)
) else (
    echo 2. Skipping Etherscan (MonadScan) - ETHERSCAN_API_KEY not set
)

echo.
echo ======================================
echo Verification Complete!
echo ======================================
echo.
echo Check your contract:
echo MonadVision: https://monadvision.com/address/%NATIVE_STAKING_ADDRESS%
echo MonadScan:   https://monadscan.com/address/%NATIVE_STAKING_ADDRESS%
echo.
pause

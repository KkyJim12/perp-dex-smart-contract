@echo off
echo ======================================
echo Kubchain Mainnet - Full Deployment
echo OneClickPerpDex + NativeStaking
echo ======================================
echo.

if not exist .env.kubchain.mainnet (
    echo Error: .env.kubchain.mainnet not found
    exit /b 1
)

for /f "tokens=*" %%a in ('type .env.kubchain.mainnet ^| findstr /v "^#"') do set %%a

if "%PRIVATE_KEY%"=="" (
    echo Error: PRIVATE_KEY not set
    exit /b 1
)

echo Network: Kubchain Mainnet
echo Chain ID: %CHAIN_ID%
echo RPC URL: %RPC_URL%
echo Backend: %BACKEND_ADDRESS%
echo.

set /p CONFIRM="WARNING: This is MAINNET. Continue? (y/n): "
if /i not "%CONFIRM%"=="y" exit /b 0

echo.
forge script script/DeployKubchainMainnet.s.sol:DeployKubchainMainnet --rpc-url %RPC_URL% --private-key %PRIVATE_KEY% --legacy --broadcast -vvvv

echo.
echo Done! Update .env.kubchain.mainnet with deployed addresses.
pause

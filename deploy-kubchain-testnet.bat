@echo off
REM Kubchain Testnet Deployment Script
REM Deploys OneClickPerpDex, ocUSDC, and optionally Mock USDC

echo ======================================
echo Kubchain Testnet Deployment
echo ======================================
echo.

REM Check if .env.kubchain exists
if not exist .env.kubchain (
    echo Error: .env.kubchain not found
    exit /b 1
)

echo Loading .env.kubchain...
for /f "tokens=*" %%a in ('type .env.kubchain ^| findstr /v "^#"') do set %%a

echo.
echo Network: Kubchain Testnet
echo Chain ID: %CHAIN_ID%
echo RPC URL: %RPC_URL%
echo Deploy Mock USDC: %DEPLOY_MOCK_USDC%
echo.

set /p CONFIRM="Continue with deployment? (y/n): "
if /i not "%CONFIRM%"=="y" (
    echo Deployment cancelled
    exit /b 0
)

echo.
echo Starting deployment...
echo.

forge script script/DeployKubchainTestnet.s.sol:DeployKubchainTestnet --rpc-url %RPC_URL% --private-key %PRIVATE_KEY% --legacy --broadcast -vvvv

echo.
echo ======================================
echo Deployment Complete!
echo ======================================
echo.
echo Check broadcast/DeployKubchainTestnet.s.sol/25925/run-latest.json for details
echo.
echo Next steps:
echo 1. Update .env.kubchain with deployed addresses
echo 2. Authorize backend address
echo 3. Add initial liquidity
echo.
pause

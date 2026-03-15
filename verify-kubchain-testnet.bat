@echo off
REM Kubchain Testnet Contract Verification Script

echo ======================================
echo Kubchain Testnet Contract Verification
echo ======================================
echo.

REM Check if .env.kubchain exists
if not exist .env.kubchain (
    echo Error: .env.kubchain not found
    exit /b 1
)

echo Loading .env.kubchain...
for /f "tokens=*" %%a in ('type .env.kubchain ^| findstr /v "^#"') do set %%a

REM Check if addresses are set
if "%USDC_ADDRESS%"=="" (
    echo Error: USDC_ADDRESS not set in .env.kubchain
    echo Please deploy contracts first or update .env.kubchain
    exit /b 1
)
if "%OCUSDC_ADDRESS%"=="" (
    echo Error: OCUSDC_ADDRESS not set in .env.kubchain
    echo Please deploy contracts first or update .env.kubchain
    exit /b 1
)
if "%ONECLICK_PERPDEX_ADDRESS%"=="" (
    echo Error: ONECLICK_PERPDEX_ADDRESS not set in .env.kubchain
    echo Please deploy contracts first or update .env.kubchain
    exit /b 1
)

echo.
echo Contract Addresses:
echo USDC: %USDC_ADDRESS%
echo ocUSDC: %OCUSDC_ADDRESS%
echo OneClickPerpDex: %ONECLICK_PERPDEX_ADDRESS%
echo.

echo Starting verification...
echo Note: Kubchain uses Blockscout which doesn't require an API key
echo.

REM Verify Mock USDC (if deployed)
if "%DEPLOY_MOCK_USDC%"=="true" (
    echo 1. Verifying Mock USDC...
    forge verify-contract %USDC_ADDRESS% src/MockUSDC.sol:MockUSDC --chain-id %CHAIN_ID% --verifier blockscout --verifier-url %VERIFIER_URL% --watch
    if errorlevel 1 echo Warning: Mock USDC verification failed (may already be verified)
    echo.
)

REM Verify ocUSDC
echo 2. Verifying ocUSDC...
forge verify-contract %OCUSDC_ADDRESS% src/ocUSDC.sol:ocUSDC --chain-id %CHAIN_ID% --verifier blockscout --verifier-url %VERIFIER_URL% --watch
if errorlevel 1 echo Warning: ocUSDC verification failed (may already be verified)
echo.

REM Verify OneClickPerpDex
echo 3. Verifying OneClickPerpDex...
for /f %%i in ('cast abi-encode "constructor(address,address)" %USDC_ADDRESS% %OCUSDC_ADDRESS%') do set CONSTRUCTOR_ARGS=%%i
forge verify-contract %ONECLICK_PERPDEX_ADDRESS% src/OneClickPerpDex.sol:OneClickPerpDex --constructor-args %CONSTRUCTOR_ARGS% --chain-id %CHAIN_ID% --verifier blockscout --verifier-url %VERIFIER_URL% --watch
if errorlevel 1 echo Warning: OneClickPerpDex verification failed (may already be verified)
echo.

echo ======================================
echo Verification Complete!
echo ======================================
echo.
echo Check contracts on Kubchain Explorer:
echo Mock USDC: https://testnet.bkcscan.com/address/%USDC_ADDRESS%
echo ocUSDC: https://testnet.bkcscan.com/address/%OCUSDC_ADDRESS%
echo OneClickPerpDex: https://testnet.bkcscan.com/address/%ONECLICK_PERPDEX_ADDRESS%
echo.
pause

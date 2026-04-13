@echo off
echo ======================================
echo Monad Mainnet - NativeStaking Deployment
echo ======================================
echo.

if not exist .env.monad (
    echo Error: .env.monad not found
    exit /b 1
)

for /f "tokens=*" %%a in ('type .env.monad ^| findstr /v "^#"') do set %%a

if "%PRIVATE_KEY%"=="" (
    echo Error: PRIVATE_KEY not set in .env.monad
    exit /b 1
)

echo Network: Monad Mainnet
echo Chain ID: %CHAIN_ID%
echo RPC URL: %RPC_URL%
echo.

set /p CONFIRM="Continue? (y/n): "
if /i not "%CONFIRM%"=="y" exit /b 0

echo.
forge script script/DeployNativeStakingMonad.s.sol:DeployNativeStakingMonad --rpc-url %RPC_URL% --private-key %PRIVATE_KEY% --broadcast -vvvv

echo.
echo Done! Update .env.monad with the deployed address.
pause

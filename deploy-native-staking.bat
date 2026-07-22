@echo off
setlocal EnableExtensions

set "ENV_FILE=%~1"
if "%ENV_FILE%"=="" set "ENV_FILE=.env"

if not exist "%ENV_FILE%" (
    echo Error: environment file not found: %ENV_FILE%
    exit /b 1
)

for /f "usebackq eol=# tokens=1,* delims==" %%A in ("%ENV_FILE%") do set "%%A=%%B"

if "%PRIVATE_KEY%"=="" (
    echo Error: PRIVATE_KEY is not set in %ENV_FILE%
    exit /b 1
)
if "%RPC_URL%"=="" (
    echo Error: RPC_URL is not set in %ENV_FILE%
    exit /b 1
)
if "%CHAIN_ID%"=="" (
    echo Error: CHAIN_ID is not set in %ENV_FILE%
    exit /b 1
)

where forge >nul 2>nul || (echo Error: forge must be installed and on PATH.& exit /b 1)
where cast >nul 2>nul || (echo Error: cast must be installed and on PATH.& exit /b 1)

for /f %%A in ('cast chain-id --rpc-url "%RPC_URL%"') do set "ACTUAL_CHAIN_ID=%%A"
if not "%ACTUAL_CHAIN_ID%"=="%CHAIN_ID%" (
    echo Error: RPC chain ID is %ACTUAL_CHAIN_ID% but CHAIN_ID is %CHAIN_ID%.
    exit /b 1
)

for /f %%A in ('cast wallet address --private-key "%PRIVATE_KEY%"') do set "DEPLOYER_ADDRESS=%%A"
for /f %%A in ('cast balance "%DEPLOYER_ADDRESS%" --rpc-url "%RPC_URL%"') do set "DEPLOYER_BALANCE=%%A"
if "%DEPLOYER_BALANCE%"=="0" (
    echo Error: deployer has no native-token balance for gas.
    exit /b 1
)

echo ======================================
echo NativeStaking deployment
echo ======================================
echo Chain ID: %CHAIN_ID%
echo RPC URL: %RPC_URL%
echo Deployer: %DEPLOYER_ADDRESS%
echo AVAX balance (wei): %DEPLOYER_BALANCE%
if not "%BACKEND_ADDRESS%"=="" echo Backend to authorize: %BACKEND_ADDRESS%
echo.

if "%CHAIN_ID%"=="43114" (
    set /p "REPLY=WARNING: This deploys to Avalanche mainnet. Continue? (y/N) "
) else (
    set /p "REPLY=Deploy NativeStaking? (y/N) "
)

if /I not "%REPLY%"=="Y" (
    echo Deployment cancelled.
    exit /b 0
)

forge script script/DeployNativeStaking.s.sol:DeployNativeStaking --rpc-url "%RPC_URL%" --broadcast -vvvv

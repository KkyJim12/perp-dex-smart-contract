@echo off
setlocal EnableExtensions

set "ENV_FILE=%~1"
if "%ENV_FILE%"=="" set "ENV_FILE=.env"

if not exist "%ENV_FILE%" (
    echo Error: environment file not found: %ENV_FILE%
    exit /b 1
)

for /f "usebackq eol=# tokens=1,* delims==" %%A in ("%ENV_FILE%") do set "%%A=%%B"

if "%RPC_URL%"=="" (
    echo Error: RPC_URL is not set in %ENV_FILE%
    exit /b 1
)
if "%CHAIN_ID%"=="" (
    echo Error: CHAIN_ID is not set in %ENV_FILE%
    exit /b 1
)
if "%NATIVE_STAKING_ADDRESS%"=="" (
    echo Error: NATIVE_STAKING_ADDRESS is not set in %ENV_FILE%
    exit /b 1
)

where forge >nul 2>nul || (echo Error: forge must be installed and on PATH.& exit /b 1)
where cast >nul 2>nul || (echo Error: cast must be installed and on PATH.& exit /b 1)

for /f %%A in ('cast chain-id --rpc-url "%RPC_URL%"') do set "ACTUAL_CHAIN_ID=%%A"
if not "%ACTUAL_CHAIN_ID%"=="%CHAIN_ID%" (
    echo Error: RPC chain ID is %ACTUAL_CHAIN_ID% but CHAIN_ID is %CHAIN_ID%.
    exit /b 1
)

if "%CHAIN_ID%"=="43114" (
    set "SNOWTRACE_API_URL=https://api.snowtrace.io/api"
    set "EXPLORER_URL=https://snowtrace.io/address/%NATIVE_STAKING_ADDRESS%"
) else if "%CHAIN_ID%"=="43113" (
    set "SNOWTRACE_API_URL=https://api-testnet.snowtrace.io/api"
    set "EXPLORER_URL=https://testnet.snowtrace.io/address/%NATIVE_STAKING_ADDRESS%"
) else (
    echo Error: Snowtrace verification is configured only for Avalanche C-Chain (43114) or Fuji (43113).
    exit /b 1
)

for /f %%A in ('cast code "%NATIVE_STAKING_ADDRESS%" --rpc-url "%RPC_URL%"') do set "ONCHAIN_CODE=%%A"
if "%ONCHAIN_CODE%"=="0x" (
    echo Error: no contract code found at %NATIVE_STAKING_ADDRESS%.
    exit /b 1
)

if "%SNOWTRACE_API_KEY%"=="" set "SNOWTRACE_API_KEY=placeholder"

echo Submitting NativeStaking for Snowtrace verification
echo Chain ID: %CHAIN_ID%
echo Contract: %NATIVE_STAKING_ADDRESS%
echo Explorer: %EXPLORER_URL%

forge verify-contract --chain %CHAIN_ID% --watch --via-ir --num-of-optimizations 200 --verifier custom --verifier-url "%SNOWTRACE_API_URL%" --verifier-api-key "%SNOWTRACE_API_KEY%" "%NATIVE_STAKING_ADDRESS%" src/NativeStaking.sol:NativeStaking

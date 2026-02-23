@echo off
REM Monad Contract Verification Script (Windows)
REM Verifies all deployed contracts using Sourcify

setlocal enabledelayedexpansion

REM Load environment variables from .env file
for /f "usebackq tokens=1,* delims==" %%a in (".env") do (
    set "%%a=%%b"
)

REM Sourcify verifier URL (MUST end with /)
set VERIFIER_URL=https://sourcify-api-monad.blockvision.org/

echo ========================================
echo Monad Contract Verification
echo ========================================
echo.

REM Function to verify a contract (simulated with goto)
goto :main

:verify_contract
set address=%~1
set contract_path=%~2
set contract_name=%~3
set constructor_args=%~4

echo Verifying %contract_name%...
echo Address: %address%
echo Contract: %contract_path%:%contract_name%

if "%constructor_args%"=="" (
    forge verify-contract --rpc-url "%RPC_URL%" --verifier sourcify --verifier-url "%VERIFIER_URL%" --chain-id %CHAIN_ID% %address% %contract_path%:%contract_name%
) else (
    forge verify-contract --rpc-url "%RPC_URL%" --verifier sourcify --verifier-url "%VERIFIER_URL%" --chain-id %CHAIN_ID% --constructor-args %constructor_args% %address% %contract_path%:%contract_name%
)

if %errorlevel% equ 0 (
    echo [SUCCESS] %contract_name% verified successfully!
) else (
    echo [FAILED] %contract_name% verification failed!
)
echo.
goto :eof

:main

REM 1. Verify MockUSDC (if deployed)
if not "%USDC_ADDRESS%"=="" (
    call :verify_contract "%USDC_ADDRESS%" "src/MockUSDC.sol" "MockUSDC" ""
)

REM 2. Verify ppUSDC (Main PerpDex LP Token)
if not "%PPUSDC_ADDRESS%"=="" (
    call :verify_contract "%PPUSDC_ADDRESS%" "src/ppUSDC.sol" "ppUSDC" ""
)

REM 3. Verify ocUSDC (OneClick PerpDex LP Token)
if not "%OCUSDC_ADDRESS%"=="" (
    call :verify_contract "%OCUSDC_ADDRESS%" "src/ocUSDC.sol" "ocUSDC" ""
)

REM 4. Verify Main PerpDex
if not "%PERPDEX_ADDRESS%"=="" (
    REM Constructor args: address _pyth, address _usdc, address _ppUSDC
    for /f %%i in ('cast abi-encode "constructor(address,address,address)" %PYTH_ADDRESS% %USDC_ADDRESS% %PPUSDC_ADDRESS%') do set CONSTRUCTOR_ARGS=%%i
    call :verify_contract "%PERPDEX_ADDRESS%" "src/PerpDex.sol" "PerpDEX" "!CONSTRUCTOR_ARGS!"
)

REM 5. Verify OneClickPerpDex
if not "%ONECLICK_PERPDEX_ADDRESS%"=="" (
    REM Constructor args: address _usdc, address _ocUSDC
    for /f %%i in ('cast abi-encode "constructor(address,address)" %USDC_ADDRESS% %OCUSDC_ADDRESS%') do set CONSTRUCTOR_ARGS=%%i
    call :verify_contract "%ONECLICK_PERPDEX_ADDRESS%" "src/OneClickPerpDex.sol" "OneClickPerpDex" "!CONSTRUCTOR_ARGS!"
)

echo ========================================
echo Verification Complete!
echo ========================================
echo.
echo Check verification status at:
echo https://explorer.monad.xyz/
echo.

endlocal
pause

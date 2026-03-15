@echo off
REM Flatten contracts for manual verification on Kubchain

echo ======================================
echo Flattening Contracts for Verification
echo ======================================
echo.

REM Create flattened directory if it doesn't exist
if not exist flattened mkdir flattened

echo Flattening MockUSDC...
forge flatten src/MockUSDC.sol --output flattened/MockUSDC_flat.sol
echo MockUSDC flattened -^> flattened/MockUSDC_flat.sol
echo.

echo Flattening ocUSDC...
forge flatten src/ocUSDC.sol --output flattened/ocUSDC_flat.sol
echo ocUSDC flattened -^> flattened/ocUSDC_flat.sol
echo.

echo Flattening OneClickPerpDex...
forge flatten src/OneClickPerpDex.sol --output flattened/OneClickPerpDex_flat.sol
echo OneClickPerpDex flattened -^> flattened/ocUSDC_flat.sol
echo.

echo ======================================
echo Flattening Complete!
echo ======================================
echo.
echo Flattened files are in the 'flattened/' directory
echo.

REM Load environment variables if available
if exist .env.kubchain (
    for /f "tokens=*" %%a in ('type .env.kubchain ^| findstr /v "^#"') do set %%a
    
    if defined USDC_ADDRESS (
        if defined OCUSDC_ADDRESS (
            echo Constructor Arguments for OneClickPerpDex:
            echo ==========================================
            for /f %%i in ('cast abi-encode "constructor(address,address)" %USDC_ADDRESS% %OCUSDC_ADDRESS%') do echo %%i
            echo.
            echo Remove the '0x' prefix when pasting into the block explorer form
            echo.
        )
    )
)

echo Next steps:
echo 1. Go to https://testnet.bkcscan.com/address/^<CONTRACT_ADDRESS^>
echo 2. Click 'Contract' tab -^> 'Verify and Publish'
echo 3. Use these settings:
echo    - Compiler: v0.8.20+commit.a1b79de6
echo    - Optimization: Yes, 200 runs
echo    - EVM Version: paris
echo 4. Paste the flattened contract code
echo.
echo See KUBCHAIN_MANUAL_VERIFY.md for detailed instructions
echo.
pause

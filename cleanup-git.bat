@echo off
REM Git Cleanup Script for Windows
REM This script removes files that should be ignored but are currently tracked

echo ========================================
echo Git Repository Cleanup
echo ========================================
echo.
echo This script will remove tracked files that should be ignored.
echo Files will be removed from Git but kept on your local machine.
echo.
set /p CONFIRM="Continue? (y/n): "

if /i not "%CONFIRM%"=="y" (
    echo Cancelled.
    exit /b 1
)

echo.
echo Removing tracked files that should be ignored...
echo.

REM Remove broadcast folder from git (keep locally)
if exist "broadcast" (
    echo Removing broadcast/ from git...
    git rm -r --cached broadcast/
)

REM Remove .env from git (keep locally)
if exist ".env" (
    echo Removing .env from git...
    git rm --cached .env
)

REM Remove cache and out folders
if exist "cache" (
    echo Removing cache/ from git...
    git rm -r --cached cache/
)

if exist "out" (
    echo Removing out/ from git...
    git rm -r --cached out/
)

REM Remove lib folder (Foundry dependencies)
if exist "lib" (
    echo Removing lib/ from git...
    git rm -r --cached lib/
)

REM Remove flattened contracts
if exist "flatten" (
    echo Removing flatten/ from git...
    git rm -r --cached flatten/
)

if exist "flattened" (
    echo Removing flattened/ from git...
    git rm -r --cached flattened/
)

REM Remove IDE files
if exist ".vscode" (
    echo Removing .vscode/ from git...
    git rm -r --cached .vscode/
)

if exist ".idea" (
    echo Removing .idea/ from git...
    git rm -r --cached .idea/
)

echo.
echo ========================================
echo Cleanup Complete!
echo ========================================
echo.
echo Files have been removed from Git but kept locally.
echo.
echo Next steps:
echo 1. Review changes: git status
echo 2. Commit changes: git commit -m "Update .gitignore and remove tracked files"
echo 3. Push changes: git push
echo.
echo Note: These files are now ignored and won't be tracked in future commits.
echo.

pause

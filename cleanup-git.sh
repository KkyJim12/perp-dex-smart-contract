#!/bin/bash

# Git Cleanup Script
# This script removes files that should be ignored but are currently tracked

echo "========================================"
echo "Git Repository Cleanup"
echo "========================================"
echo ""
echo "This script will remove tracked files that should be ignored."
echo "Files will be removed from Git but kept on your local machine."
echo ""
read -p "Continue? (y/n) " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 1
fi

echo ""
echo "Removing tracked files that should be ignored..."
echo ""

# Remove broadcast folder from git (keep locally)
if [ -d "broadcast" ]; then
    echo "Removing broadcast/ from git..."
    git rm -r --cached broadcast/
fi

# Remove .env from git (keep locally)
if [ -f ".env" ]; then
    echo "Removing .env from git..."
    git rm --cached .env
fi

# Remove cache and out folders
if [ -d "cache" ]; then
    echo "Removing cache/ from git..."
    git rm -r --cached cache/
fi

if [ -d "out" ]; then
    echo "Removing out/ from git..."
    git rm -r --cached out/
fi

# Remove lib folder (Foundry dependencies)
if [ -d "lib" ]; then
    echo "Removing lib/ from git..."
    git rm -r --cached lib/
fi

# Remove flattened contracts
if [ -d "flatten" ]; then
    echo "Removing flatten/ from git..."
    git rm -r --cached flatten/
fi

if [ -d "flattened" ]; then
    echo "Removing flattened/ from git..."
    git rm -r --cached flattened/
fi

# Remove any .flat.sol files
find . -name "*.flat.sol" -type f | while read file; do
    if git ls-files --error-unmatch "$file" > /dev/null 2>&1; then
        echo "Removing $file from git..."
        git rm --cached "$file"
    fi
done

# Remove IDE files
if [ -d ".vscode" ]; then
    echo "Removing .vscode/ from git..."
    git rm -r --cached .vscode/
fi

if [ -d ".idea" ]; then
    echo "Removing .idea/ from git..."
    git rm -r --cached .idea/
fi

# Remove OS files
find . -name ".DS_Store" -type f | while read file; do
    if git ls-files --error-unmatch "$file" > /dev/null 2>&1; then
        echo "Removing $file from git..."
        git rm --cached "$file"
    fi
done

echo ""
echo "========================================"
echo "Cleanup Complete!"
echo "========================================"
echo ""
echo "Files have been removed from Git but kept locally."
echo ""
echo "Next steps:"
echo "1. Review changes: git status"
echo "2. Commit changes: git commit -m 'Update .gitignore and remove tracked files'"
echo "3. Push changes: git push"
echo ""
echo "Note: These files are now ignored and won't be tracked in future commits."
echo ""

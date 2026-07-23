// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "lib/forge-std/src/Test.sol";
import "../src/PermissionlessPerpDex.sol";
import "../src/MockUSDC.sol";
import "../src/ppUSDC.sol";

contract PermissionlessPerpDexTest is Test {
    PermissionlessPerpDex public perpDex;
    MockUSDC public usdc;
    ppUSDC public ppusdc;
    
    address public owner = address(0x1);
    address public backend = address(0x2);
    address public user1 = address(0x3);
    address public user2 = address(0x4);
    address public lp1 = address(0x5);
    
    uint256 public constant INITIAL_BALANCE = 10000e6; // 10,000 USDC
    
    function setUp() public {
        // Deploy contracts
        vm.startPrank(owner);
        usdc = new MockUSDC();
        ppusdc = new ppUSDC();
        perpDex = new PermissionlessPerpDex(address(usdc), address(ppusdc));
        
        // Set PermissionlessPerpDex as ppUSDC minter
        ppusdc.setMinter(address(perpDex), true);
        
        // Authorize backend
        perpDex.authorizeBackend(backend, true);
        vm.stopPrank();
        
        // Give users and LPs USDC
        usdc.ownerMint(user1, INITIAL_BALANCE);
        usdc.ownerMint(user2, INITIAL_BALANCE);
        usdc.ownerMint(lp1, INITIAL_BALANCE);
        
        // Approve spending
        vm.prank(user1);
        usdc.approve(address(perpDex), type(uint256).max);
        
        vm.prank(user2);
        usdc.approve(address(perpDex), type(uint256).max);
        
        vm.prank(lp1);
        usdc.approve(address(perpDex), type(uint256).max);
    }
    
    function testDeposit() public {
        uint256 depositAmount = 1000e6; // 1,000 USDC
        
        vm.prank(user1);
        perpDex.deposit(depositAmount);
        
        assertEq(perpDex.userBalances(user1), depositAmount);
        assertEq(perpDex.getAvailableBalance(user1), depositAmount);
        assertEq(usdc.balanceOf(address(perpDex)), depositAmount);
    }
    
    function testWithdraw() public {
        uint256 depositAmount = 1000e6;
        uint256 withdrawAmount = 500e6;
        
        // Deposit first
        vm.prank(user1);
        perpDex.deposit(depositAmount);
        
        // Withdraw
        vm.prank(user1);
        perpDex.withdraw(withdrawAmount);
        
        assertEq(perpDex.userBalances(user1), depositAmount - withdrawAmount);
        assertEq(usdc.balanceOf(user1), INITIAL_BALANCE - depositAmount + withdrawAmount);
    }
    
    function testOpenPosition() public {
        uint256 depositAmount = 1000e6;
        uint256 margin = 100e6; // 100 USDC
        uint256 leverage = 10;
        uint256 entryPrice = 50000e8; // $50,000 (8 decimals like Pyth)
        
        // User deposits
        vm.prank(user1);
        perpDex.deposit(depositAmount);
        
        // Backend opens position
        vm.prank(backend);
        bytes32 positionId = perpDex.openPosition(
            user1,
            "BTC_USD",
            true, // long
            margin,
            leverage,
            entryPrice
        );
        
        // Check position
        PermissionlessPerpDex.Position memory pos = perpDex.getPosition(positionId);
        assertEq(pos.user, user1);
        assertEq(pos.margin, margin);
        assertEq(pos.leverage, leverage);
        assertEq(pos.size, margin * leverage);
        assertEq(pos.entryPrice, entryPrice);
        assertTrue(pos.isActive);
        
        // Check balances
        assertEq(perpDex.lockedBalances(user1), margin);
        assertEq(perpDex.getAvailableBalance(user1), depositAmount - margin);
    }
    
    function testClosePositionProfit() public {
        uint256 depositAmount = 1000e6;
        uint256 margin = 100e6;
        uint256 leverage = 10;
        uint256 entryPrice = 50000e8; // $50,000
        uint256 exitPrice = 55000e8;  // $55,000 (+10% profit)
        
        // Setup position
        vm.prank(user1);
        perpDex.deposit(depositAmount);
        
        vm.prank(backend);
        bytes32 positionId = perpDex.openPosition(user1, "BTC_USD", true, margin, leverage, entryPrice);
        
        uint256 balanceBeforeClose = perpDex.userBalances(user1);
        
        // Close position with profit
        vm.prank(backend);
        perpDex.closePosition(positionId, exitPrice, "manual_close");
        
        // Check position is closed
        PermissionlessPerpDex.Position memory pos = perpDex.getPosition(positionId);
        assertFalse(pos.isActive);
        
        // Check PnL calculation
        int256 expectedPnL = perpDex.calculatePnL(pos, exitPrice);
        assertGt(expectedPnL, 0); // Should be positive (profit)
        
        // Check user balance increased (minus fees)
        assertGt(perpDex.userBalances(user1), balanceBeforeClose);
        assertEq(perpDex.lockedBalances(user1), 0); // No more locked funds
    }
    
    function testClosePositionLoss() public {
        uint256 depositAmount = 1000e6;
        uint256 margin = 100e6;
        uint256 leverage = 10;
        uint256 entryPrice = 50000e8; // $50,000
        uint256 exitPrice = 45000e8;  // $45,000 (-10% loss)
        
        // Setup position
        vm.prank(user1);
        perpDex.deposit(depositAmount);
        
        vm.prank(backend);
        bytes32 positionId = perpDex.openPosition(user1, "BTC_USD", true, margin, leverage, entryPrice);
        
        uint256 balanceBeforeClose = perpDex.userBalances(user1);
        
        // Close position with loss
        vm.prank(backend);
        perpDex.closePosition(positionId, exitPrice, "manual_close");
        
        // Check PnL calculation
        PermissionlessPerpDex.Position memory pos = perpDex.getPosition(positionId);
        int256 expectedPnL = perpDex.calculatePnL(pos, exitPrice);
        assertLt(expectedPnL, 0); // Should be negative (loss)
        
        // Check user balance decreased
        assertLt(perpDex.userBalances(user1), balanceBeforeClose);
    }
    
    function testLiquidation() public {
        uint256 depositAmount = 1000e6;
        uint256 margin = 100e6;
        uint256 leverage = 10;
        uint256 entryPrice = 50000e8;
        uint256 liquidationPrice = 45000e8; // Significant loss
        
        // Setup position
        vm.prank(user1);
        perpDex.deposit(depositAmount);
        
        vm.prank(backend);
        bytes32 positionId = perpDex.openPosition(user1, "BTC_USD", true, margin, leverage, entryPrice);
        
        uint256 balanceBeforeLiq = perpDex.userBalances(user1);
        
        // Liquidate position
        vm.prank(backend);
        perpDex.liquidatePosition(positionId, liquidationPrice);
        
        // Check position is closed
        PermissionlessPerpDex.Position memory pos = perpDex.getPosition(positionId);
        assertFalse(pos.isActive);
        
        // User should lose entire margin on liquidation
        assertEq(perpDex.userBalances(user1), balanceBeforeLiq); // No payout
        assertEq(perpDex.lockedBalances(user1), 0); // Funds unlocked but lost
    }
    
    function testMultiplePositions() public {
        uint256 depositAmount = 1000e6;
        uint256 margin = 100e6;
        
        vm.prank(user1);
        perpDex.deposit(depositAmount);
        
        // Open multiple positions
        vm.startPrank(backend);
        bytes32 pos1 = perpDex.openPosition(user1, "BTC_USD", true, margin, 10, 50000e8);
        bytes32 pos2 = perpDex.openPosition(user1, "ETH_USD", false, margin, 5, 3000e8);
        bytes32 pos3 = perpDex.openPosition(user1, "SOL_USD", true, margin, 20, 100e8);
        vm.stopPrank();
        
        // Check user has 3 active positions
        assertEq(perpDex.getUserActivePositionsCount(user1), 3);
        assertEq(perpDex.lockedBalances(user1), margin * 3);
        
        bytes32[] memory activePositions = perpDex.getUserActivePositions(user1);
        assertEq(activePositions.length, 3);
        
        // Close one position
        vm.prank(backend);
        perpDex.closePosition(pos2, 2900e8, "manual_close");
        
        // Check counts updated
        assertEq(perpDex.getUserActivePositionsCount(user1), 2);
    }
    
    function testUnauthorizedBackend() public {
        address unauthorizedBackend = address(0x999);
        
        vm.prank(user1);
        perpDex.deposit(1000e6);
        
        // Should fail - unauthorized backend
        vm.prank(unauthorizedBackend);
        vm.expectRevert("Not authorized backend");
        perpDex.openPosition(user1, "BTC_USD", true, 100e6, 10, 50000e8);
    }
    
    function testInsufficientBalance() public {
        uint256 depositAmount = 100e6;
        uint256 margin = 200e6; // More than deposited
        
        vm.prank(user1);
        perpDex.deposit(depositAmount);
        
        // Should fail - insufficient balance
        vm.prank(backend);
        vm.expectRevert("Insufficient balance");
        perpDex.openPosition(user1, "BTC_USD", true, margin, 10, 50000e8);
    }
    
    function testPnLCalculation() public {
        // Test long position profit
        PermissionlessPerpDex.Position memory longPos = PermissionlessPerpDex.Position({
            id: bytes32(0),
            user: user1,
            pair: "BTC_USD",
            isLong: true,
            margin: 100e6,
            leverage: 10,
            size: 1000e6,
            entryPrice: 50000e8,
            timestamp: block.timestamp,
            isActive: true
        });
        
        // Price goes up 10% - should be 10% profit on size
        int256 pnl = perpDex.calculatePnL(longPos, 55000e8);
        assertEq(pnl, int256(longPos.size * 10 / 100)); // 10% of size
        
        // Test short position profit
        PermissionlessPerpDex.Position memory shortPos = longPos;
        shortPos.isLong = false;
        
        // Price goes down 10% - should be 10% profit on size for short
        pnl = perpDex.calculatePnL(shortPos, 45000e8);
        assertEq(pnl, int256(shortPos.size * 10 / 100)); // 10% of size
    }
    
    function testContractStats() public {
        // Add some activity
        vm.prank(user1);
        perpDex.deposit(1000e6);
        
        vm.prank(user2);
        perpDex.deposit(500e6);
        
        vm.prank(backend);
        perpDex.openPosition(user1, "BTC_USD", true, 100e6, 10, 50000e8);
        
        (
            uint256 totalUsers,
            uint256 totalPositionsCount,
            uint256 activePositionsCount,
            uint256 contractBalance,
            uint256 totalDeposits,
            uint256 totalWithdrawals,
            uint256 totalLockedFunds,
            uint256 totalFeesCollected
        ) = perpDex.getContractStats();
        
        assertEq(totalPositionsCount, 1);
        assertEq(activePositionsCount, 1);
        assertEq(contractBalance, 1500e6); // Both deposits
        assertEq(totalDeposits, 1500e6);
        assertEq(totalWithdrawals, 0);
        assertEq(totalLockedFunds, 100e6);
    }
}

    
    function testLPDeposit() public {
        uint256 depositAmount = 1000e6; // 1,000 USDC
        
        vm.prank(lp1);
        perpDex.depositLP(depositAmount);
        
        assertEq(ppusdc.balanceOf(lp1), depositAmount); // 1:1 for first deposit
        assertEq(perpDex.getPoolValue(), depositAmount);
        assertEq(usdc.balanceOf(address(perpDex)), depositAmount);
    }
    
    function testLPWithdraw() public {
        uint256 depositAmount = 1000e6;
        
        // LP deposits
        vm.prank(lp1);
        perpDex.depositLP(depositAmount);
        
        // LP withdraws half
        uint256 withdrawShares = 500e6;
        vm.prank(lp1);
        perpDex.withdrawLP(withdrawShares);
        
        assertEq(ppusdc.balanceOf(lp1), depositAmount - withdrawShares);
        assertEq(perpDex.getPoolValue(), depositAmount - withdrawShares);
    }
    
    function testTraderVsPoolPnL() public {
        // LP provides liquidity
        vm.prank(lp1);
        perpDex.depositLP(1000e6);
        
        uint256 depositAmount = 1000e6;
        uint256 margin = 100e6;
        uint256 leverage = 10;
        uint256 entryPrice = 50000e8;
        uint256 exitPrice = 55000e8; // 10% profit for trader
        
        // Trader deposits
        vm.prank(user1);
        perpDex.deposit(depositAmount);
        
        // Backend opens position
        vm.prank(backend);
        bytes32 positionId = perpDex.openPosition(user1, "BTC_USD", true, margin, leverage, entryPrice);
        
        // Close position with profit
        vm.prank(backend);
        perpDex.closePosition(positionId, exitPrice, "manual_close");
        
        // Check pool PnL (should be negative since trader won)
        (int256 poolPnL, uint256 poolProfit, uint256 poolLoss, ) = perpDex.getPoolStats();
        assertLt(poolPnL, 0); // Pool lost money
        assertGt(poolLoss, 0); // Pool has losses
    }
    
    function testPoolGainsOnLiquidation() public {
        // LP provides liquidity
        vm.prank(lp1);
        perpDex.depositLP(1000e6);
        
        uint256 depositAmount = 1000e6;
        uint256 margin = 100e6;
        uint256 leverage = 10;
        uint256 entryPrice = 50000e8;
        uint256 liquidationPrice = 45000e8;
        
        // Trader deposits
        vm.prank(user1);
        perpDex.deposit(depositAmount);
        
        // Backend opens position
        vm.prank(backend);
        bytes32 positionId = perpDex.openPosition(user1, "BTC_USD", true, margin, leverage, entryPrice);
        
        // Liquidate position
        vm.prank(backend);
        perpDex.liquidatePosition(positionId, liquidationPrice);
        
        // Check pool PnL (should be positive - pool gained trader's margin)
        (int256 poolPnL, uint256 poolProfit, , ) = perpDex.getPoolStats();
        assertEq(poolPnL, int256(margin)); // Pool gained full margin
        assertEq(poolProfit, margin);
    }
    
    function testPoolValueExcludesTraderMargins() public {
        // LP deposits
        vm.prank(lp1);
        perpDex.depositLP(1000e6);
        
        uint256 initialPoolValue = perpDex.getPoolValue();
        assertEq(initialPoolValue, 1000e6);
        
        // Trader deposits
        vm.prank(user1);
        perpDex.deposit(500e6);
        
        // Pool value should still be 1000 (trader deposit doesn't affect pool)
        assertEq(perpDex.getPoolValue(), 1000e6);
        
        // Trader opens position
        vm.prank(backend);
        perpDex.openPosition(user1, "BTC_USD", true, 100e6, 10, 50000e8);
        
        // Pool value should still be 1000 (trader margin is locked, not in pool)
        assertEq(perpDex.getPoolValue(), 1000e6);
    }

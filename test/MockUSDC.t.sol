// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

contract MockUSDCTest is Test {
    MockUSDC internal usdc;
    address internal user = makeAddr("user");
    address internal other = makeAddr("other");

    function setUp() public {
        usdc = new MockUSDC();
    }

    function testOwnerCanMintAnyAmount() public {
        usdc.ownerMint(user, 12_345_678);

        assertEq(usdc.balanceOf(user), 12_345_678);
    }

    function testNonOwnerCannotOwnerMint() public {
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user)
        );
        usdc.ownerMint(user, 1);
    }

    function testUserCanMintExactlyOneThousandUSDCOnce() public {
        vm.prank(user);
        usdc.mint();

        assertTrue(usdc.hasMinted(user));
        assertEq(usdc.balanceOf(user), 1_000e6);
        assertEq(usdc.balanceOf(user), usdc.USER_MINT_AMOUNT());
    }

    function testOwnerCanDisableAndEnableUserMinting() public {
        usdc.setUserMintEnabled(false);
        assertFalse(usdc.userMintEnabled());

        vm.prank(user);
        vm.expectRevert("User mint disabled");
        usdc.mint();

        usdc.setUserMintEnabled(true);
        vm.prank(user);
        usdc.mint();

        assertEq(usdc.balanceOf(user), 1_000e6);
    }

    function testNonOwnerCannotChangeUserMintStatus() public {
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user)
        );
        usdc.setUserMintEnabled(false);
    }

    function testUserCannotMintTwice() public {
        vm.startPrank(user);
        usdc.mint();
        vm.expectRevert("USDC already claimed");
        usdc.mint();
        vm.stopPrank();
    }

    function testEachWalletCanMintOnce() public {
        vm.prank(user);
        usdc.mint();
        vm.prank(other);
        usdc.mint();

        assertEq(usdc.balanceOf(user), 1_000e6);
        assertEq(usdc.balanceOf(other), 1_000e6);
    }
}

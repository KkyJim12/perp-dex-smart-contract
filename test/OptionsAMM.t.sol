// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PythStructs} from "pyth-sdk-solidity/PythStructs.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {OptionsAMM} from "../src/OptionsAMM.sol";
import {opUSDC} from "../src/opUSDC.sol";

contract OptionsMockPyth {
    PythStructs.Price internal price;
    function setPrice(uint256 value) external { price = PythStructs.Price(int64(int256(value)), 0, 0, block.timestamp); }
    function getUpdateFee(bytes[] calldata) external pure returns (uint256) { return 0; }
    function updatePriceFeeds(bytes[] calldata updateData) external payable { if (updateData.length != 0) price = PythStructs.Price(int64(int256(abi.decode(updateData[0], (uint256)))), 0, 0, block.timestamp); }
    function getPrice(bytes32) external view returns (PythStructs.Price memory) { return price; }
}

contract OptionsAMMTest is Test {
    MockUSDC usdc; opUSDC shares; OptionsAMM amm; OptionsMockPyth pyth;
    address lp = makeAddr("lp"); address buyer = makeAddr("buyer");
    bytes32 constant BTC = bytes32(uint256(1));

    function setUp() public {
        usdc = new MockUSDC(); shares = new opUSDC(); pyth = new OptionsMockPyth();
        amm = new OptionsAMM(address(usdc), address(pyth), address(shares));
        shares.setOptionsAMM(address(amm));
        usdc.ownerMint(lp, 10_000e6); usdc.ownerMint(buyer, 1_000e6);
        vm.prank(lp); usdc.approve(address(amm), type(uint256).max);
        vm.prank(buyer); usdc.approve(address(amm), type(uint256).max);
        vm.prank(lp); amm.deposit(10_000e6);
    }

    function testLpSharesTrackVaultAndVaultIsCounterparty() public {
        uint256 id = amm.createMarket(BTC, 100e8, block.timestamp + 1 days, 1_000, true);
        vm.prank(buyer); uint256 position = amm.buyOption(id, 1_000e6, 100e6);
        assertEq(amm.reservedPayout(), 1_000e6);
        assertEq(amm.vaultValue(), 9_100e6); // 10,000 + 100 premium - 1,000 maximum liability
        vm.warp(block.timestamp + 1 days);
        pyth.setPrice(150e8);
        amm.settleOption(buyer, position, new bytes[](0));
        assertEq(usdc.balanceOf(buyer), 1_400e6); // 1,000 - premium + 500 payoff
        assertEq(amm.reservedPayout(), 0);
        assertEq(amm.lpShareValue(lp), 9_600e6);
    }

    function testLiquidityIsLockedUntilReservedOptionCollateralIsReleased() public {
        uint256 id = amm.createMarket(BTC, 100e8, block.timestamp + 1 days, 1_000, true);
        vm.prank(buyer); amm.buyOption(id, 1_000e6, 100e6);
        uint256 lpShares = shares.balanceOf(lp);
        vm.prank(lp);
        vm.expectRevert("Liquidity locked by open options");
        amm.withdraw(lpShares);

        vm.warp(block.timestamp + 1 days);
        pyth.setPrice(100e8);
        amm.settleOption(buyer, 0, new bytes[](0));
        vm.prank(lp); amm.withdraw(lpShares);
        assertEq(usdc.balanceOf(address(amm)), 0);
    }
}

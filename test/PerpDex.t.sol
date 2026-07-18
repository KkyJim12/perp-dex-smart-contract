// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PythStructs} from "pyth-sdk-solidity/PythStructs.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {PerpDEX} from "../src/PerpDex.sol";
import {ppUSDC} from "../src/ppUSDC.sol";

contract MaxTPMockPyth {
    PythStructs.Price internal currentPrice;

    function setPrice(uint256 price) external {
        currentPrice = PythStructs.Price({
            price: int64(int256(price)),
            conf: 0,
            expo: 0,
            publishTime: block.timestamp
        });
    }

    function getUpdateFee(
        bytes[] calldata
    ) external pure returns (uint256) {
        return 0;
    }

    function updatePriceFeeds(bytes[] calldata) external payable {}

    function getPrice(
        bytes32
    ) external view returns (PythStructs.Price memory) {
        return currentPrice;
    }

    function getPriceUnsafe(
        bytes32
    ) external view returns (PythStructs.Price memory) {
        return currentPrice;
    }
}

contract PerpDexTest is Test {
    uint256 internal constant ENTRY_PRICE = 50_000e8;
    uint256 internal constant MARGIN = 100e6;
    uint256 internal constant LEVERAGE = 10;

    address internal trader = makeAddr("trader");

    MockUSDC internal usdc;
    ppUSDC internal lpToken;
    MaxTPMockPyth internal mockPyth;
    PerpDEX internal perpDex;

    function setUp() public {
        usdc = new MockUSDC();
        lpToken = new ppUSDC();
        mockPyth = new MaxTPMockPyth();
        mockPyth.setPrice(ENTRY_PRICE);

        perpDex = new PerpDEX(
            address(usdc),
            address(mockPyth),
            address(lpToken)
        );
        perpDex.addPair(
            "BTC_USD",
            bytes32(uint256(1)),
            20,
            50_000e6,
            2,
            100,
            5e18
        );
        lpToken.setMinter(address(perpDex), true);

        usdc.mint(address(this), 100_000_000e6);
        usdc.approve(address(perpDex), type(uint256).max);
        perpDex.depositLP(100_000_000e6);

        usdc.mint(trader, MARGIN * 10);
        vm.prank(trader);
        usdc.approve(address(perpDex), type(uint256).max);
    }

    function testOpenWithoutTPDefaultsToPairMaxTP() public {
        perpDex.updatePairMaxTP("BTC_USD", 2e18); // 200% of margin

        _openLong(0);

        (, , uint256 takeProfit) = _positionData(0);
        // At 10x leverage, 200% ROI is a 20% favorable price move.
        assertEq(takeProfit, 60_000e8);
    }

    function testConstructorDoesNotAddPairs() public {
        PerpDEX emptyDex = new PerpDEX(
            address(usdc),
            address(mockPyth),
            address(lpToken)
        );
        (string[] memory names, , , , , ) = emptyDex.getAllPairsOI();
        assertEq(names.length, 0);
    }

    function testOpenRejectsTPAbovePairMaxTP() public {
        perpDex.updatePairMaxTP("BTC_USD", 1e18); // 100% of margin

        vm.expectRevert("TP exceeds pair maxTP");
        _openLong(56_000e8); // 120% ROI at 10x
    }

    function testShortDefaultAndMaxTPValidation() public {
        perpDex.updatePairMaxTP("BTC_USD", 1e18);

        _openShort(0);
        (, , uint256 takeProfit) = _positionData(0);
        assertEq(takeProfit, 45_000e8);

        vm.expectRevert("TP exceeds pair maxTP");
        _openShort(44_000e8); // 120% ROI at 10x
    }

    function testModifyRejectsTPAbovePairMaxTP() public {
        perpDex.updatePairMaxTP("BTC_USD", 1e18);
        _openLong(0);

        (bytes32 positionId, , ) = _positionData(0);

        vm.prank(trader);
        vm.expectRevert("TP exceeds pair maxTP");
        perpDex.modifyTpSl(positionId, 56_000e8, 0);
    }

    function testModifyZeroTPResetsToPairMaxTP() public {
        perpDex.updatePairMaxTP("BTC_USD", 2e18);
        _openLong(55_000e8);

        (bytes32 positionId, , ) = _positionData(0);

        vm.prank(trader);
        perpDex.modifyTpSl(positionId, 0, 0);

        (, , uint256 takeProfit) = _positionData(0);
        assertEq(takeProfit, 60_000e8);
    }

    function testCloseCapsProfitAtPairMaxTP() public {
        perpDex.updatePairMaxTP("BTC_USD", 1e18); // Max profit = 100 USDC
        _openLong(0);

        (bytes32 positionId, , ) = _positionData(0);
        mockPyth.setPrice(100_000e8); // Uncapped profit would be 1,000% ROI

        bytes[] memory updateData = new bytes[](0);
        vm.prank(trader);
        perpDex.closePosition(positionId, updateData);

        (, uint256 payout, ) = _positionData(0);
        // 100 margin + 100 capped profit - 2% fee on the 100 profit.
        assertEq(payout, 198e6);
        assertEq(usdc.balanceOf(trader), (MARGIN * 9) + 198e6);
    }

    function testPairMaxTPSetterRejectsUnusableValue() public {
        // At 100x max leverage this would put default TP less than 0.1%
        // from entry, conflicting with the contract's minimum TP distance.
        vm.expectRevert("maxTP too low for max leverage");
        perpDex.updatePairMaxTP("BTC_USD", 0.05e18);
    }

    function _openLong(uint256 takeProfit) internal {
        bytes[] memory updateData = new bytes[](0);
        vm.prank(trader);
        perpDex.openPosition(
            "BTC_USD",
            true,
            MARGIN,
            LEVERAGE,
            updateData,
            takeProfit,
            0
        );
    }

    function _openShort(uint256 takeProfit) internal {
        bytes[] memory updateData = new bytes[](0);
        vm.prank(trader);
        perpDex.openPosition(
            "BTC_USD",
            false,
            MARGIN,
            LEVERAGE,
            updateData,
            takeProfit,
            0
        );
    }

    function _positionData(
        uint256 index
    ) internal view returns (bytes32 id, uint256 payout, uint256 takeProfit) {
        (
            id,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            payout,
            ,
            ,
            ,
            takeProfit,

        ) = perpDex.positions(trader, index);
    }
}

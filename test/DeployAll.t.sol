// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DeployAll} from "../script/DeployAll.s.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {OptionsAMM} from "../src/OptionsAMM.sol";
import {opUSDC} from "../src/opUSDC.sol";
import {PredictionMarketAMM} from "../src/PredictionMarketAMM.sol";
import {pmUSDC} from "../src/pmUSDC.sol";

contract DeployAllTest is Test {
    DeployAll script;
    address pyth = address(0x1234);

    function setUp() public {
        script = DeployAll(deployCode("DeployAll.s.sol:DeployAll"));
        vm.setEnv("PRIVATE_KEY", "1");
        vm.setEnv("PYTH_ADDRESS", vm.toString(pyth));
        vm.setEnv("PREDICTION_FEE_BPS", "30");
        vm.etch(pyth, hex"00");
        vm.deal(vm.addr(1), 100 ether);
    }

    // Keep environment-dependent scenarios together: setEnv changes process-wide
    // state, which is not reverted with Foundry's per-test EVM snapshots.
    function testDeployAllConfigurations() public {
        vm.setEnv("DEPLOY_MOCK_USDC", "true");
        _checkDeployment(address(0), 30);

        MockUSDC existing = new MockUSDC();
        vm.setEnv("DEPLOY_MOCK_USDC", "false");
        vm.setEnv("USDC_ADDRESS", vm.toString(address(existing)));
        vm.setEnv("PREDICTION_FEE_BPS", "125");
        _checkDeployment(address(existing), 125);

        vm.setEnv("PREDICTION_FEE_BPS", "501");
        vm.expectRevert("Prediction fee exceeds 5%");
        script.run();
    }

    function _checkDeployment(address existingUSDC, uint256 fee) internal {
        (
            address usdc, address perpShares, address perp, address oneClickShares,
            address oneClick, address optionsShares, address options,
            address predictionShares, address prediction
        ) = script.run();

        if (existingUSDC != address(0)) assertEq(usdc, existingUSDC);
        assertGt(usdc.code.length, 0);
        assertGt(perp.code.length, 0);
        assertGt(oneClick.code.length, 0);

        assertEq(opUSDC(optionsShares).optionsAMM(), options);
        assertEq(OptionsAMM(options).owner(), vm.addr(1));
        assertEq(opUSDC(optionsShares).owner(), vm.addr(1));
        assertEq(address(OptionsAMM(options).usdc()), usdc);
        assertEq(address(OptionsAMM(options).pyth()), pyth);
        assertEq(address(OptionsAMM(options).opUSDC()), optionsShares);

        PredictionMarketAMM vault = PredictionMarketAMM(prediction);
        assertEq(vault.owner(), vm.addr(1));
        assertEq(address(vault.usdc()), usdc);
        assertEq(address(vault.pyth()), pyth);
        assertEq(address(vault.shareToken()), predictionShares);
        assertEq(pmUSDC(predictionShares).vault(), prediction);
        assertEq(vault.feeBps(), fee);
        assertEq(vault.priceIds(0), 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43);
        assertEq(vault.priceIds(1), 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace);
        assertEq(vault.priceIds(2), 0xef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d);
        assertEq(vault.marketCount(), 0);

        assertTrue(optionsShares != perpShares && optionsShares != oneClickShares);
        assertTrue(predictionShares != optionsShares && predictionShares != perpShares);
        assertTrue(predictionShares != oneClickShares);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DeployAll} from "../script/DeployAll.s.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {OptionAMM} from "../src/OptionAMM.sol";
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
        vm.setEnv("PREDICTION_FEE_BPS", "300");
        vm.etch(pyth, hex"00");
        vm.deal(vm.addr(1), 100 ether);
    }

    // Keep environment-dependent scenarios together: setEnv changes process-wide
    // state, which is not reverted with Foundry's per-test EVM snapshots.
    function testDeployAllConfigurations() public {
        vm.setEnv("DEPLOY_MOCK_USDC", "true");
        _checkDeployment(address(0), 300);

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
            address oneClick, address optionShares, address option,
            address predictionShares, address prediction
        ) = script.run();

        if (existingUSDC != address(0)) assertEq(usdc, existingUSDC);
        assertGt(usdc.code.length, 0);
        assertGt(perp.code.length, 0);
        assertGt(oneClick.code.length, 0);

        assertEq(opUSDC(optionShares).optionAMM(), option);
        assertEq(OptionAMM(option).owner(), vm.addr(1));
        assertEq(opUSDC(optionShares).owner(), vm.addr(1));
        assertEq(address(OptionAMM(option).usdc()), usdc);
        assertEq(address(OptionAMM(option).pyth()), pyth);
        assertEq(address(OptionAMM(option).opUSDC()), optionShares);

        PredictionMarketAMM vault = PredictionMarketAMM(prediction);
        assertEq(vault.owner(), vm.addr(1));
        assertEq(address(vault.usdc()), usdc);
        assertEq(address(vault.pyth()), pyth);
        assertEq(address(vault.shareToken()), predictionShares);
        assertEq(pmUSDC(predictionShares).vault(), prediction);
        assertEq(vault.feeBps(), fee);
        assertEq(vault.pairCount(), 0);
        assertEq(vault.marketCount(), 0);

        assertTrue(optionShares != perpShares && optionShares != oneClickShares);
        assertTrue(predictionShares != optionShares && predictionShares != perpShares);
        assertTrue(predictionShares != oneClickShares);
    }
}

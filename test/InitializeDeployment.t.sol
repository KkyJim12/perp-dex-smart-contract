// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {InitializeDeployment} from "../script/InitializeDeployment.s.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {OneClickPerpDex} from "../src/OneClickPerpDex.sol";
import {OptionsAMM} from "../src/OptionsAMM.sol";
import {opUSDC} from "../src/opUSDC.sol";

contract InitializeDeploymentTest is Test {
    function testInitializeAuthorizesConfiguredBackend() public {
        address owner = vm.addr(1);
        address backend = makeAddr("configuredBackend");
        address replacementBackend = makeAddr("replacementBackend");
        vm.deal(owner, 100 ether);
        vm.etch(address(0x1234), hex"00");

        vm.startPrank(owner);
        MockUSDC usdc = MockUSDC(deployCode("MockUSDC.sol:MockUSDC"));
        OneClickPerpDex dex = OneClickPerpDex(
            payable(deployCode("OneClickPerpDex.sol:OneClickPerpDex", abi.encode(address(usdc), address(0x1234))))
        );
        opUSDC optionShares = opUSDC(deployCode("opUSDC.sol:opUSDC"));
        OptionsAMM options = OptionsAMM(
            deployCode("OptionsAMM.sol:OptionsAMM", abi.encode(address(usdc), address(0x1234), address(optionShares)))
        );
        optionShares.setOptionsAMM(address(options));
        vm.stopPrank();
        InitializeDeployment initializer =
            InitializeDeployment(deployCode("InitializeDeployment.s.sol:InitializeDeployment"));

        // Keep environment scenarios together: setEnv affects the entire process.
        vm.setEnv("PRIVATE_KEY", "1");
        vm.setEnv("USDC_ADDRESS", vm.toString(address(usdc)));
        vm.setEnv("ONECLICK_PERPDEX_ADDRESS", vm.toString(address(dex)));
        vm.setEnv("OPTIONS_AMM_ADDRESS", vm.toString(address(options)));
        vm.setEnv("BACKEND_ADDRESS", vm.toString(backend));
        vm.setEnv("DEPLOY_MOCK_USDC", "true");
        vm.setEnv("INITIAL_MOCK_USDC_MINT_AMOUNT", "123000000");
        initializer.run();

        assertTrue(dex.authorizedBackends(backend));
        assertTrue(options.authorizedBackends(backend));
        assertFalse(options.authorizedBackends(owner));
        assertFalse(dex.authorizedBackends(owner));
        assertEq(usdc.balanceOf(owner), 123e6);
        assertEq(usdc.balanceOf(backend), 0);

        // Re-authorizing the configured backend is allowed without minting.
        vm.setEnv("DEPLOY_MOCK_USDC", "false");
        initializer.run();
        assertTrue(dex.authorizedBackends(backend));
        assertEq(usdc.balanceOf(owner), 123e6);

        vm.setEnv("BACKEND_ADDRESS", vm.toString(replacementBackend));
        initializer.run();
        assertTrue(dex.authorizedBackends(replacementBackend));
        assertTrue(options.authorizedBackends(replacementBackend));
        assertFalse(dex.authorizedBackends(owner));

        vm.setEnv("BACKEND_ADDRESS", vm.toString(address(0)));
        vm.expectRevert("Invalid backend address");
        initializer.run();
        assertFalse(dex.authorizedBackends(address(0)));
    }
}

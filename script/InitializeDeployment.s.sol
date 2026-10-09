// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "lib/forge-std/src/Script.sol";
import "../src/MockUSDC.sol";
import "../src/OneClickPerpDex.sol";
import "../src/OptionsAMM.sol";

/// @notice Performs the owner-only setup actions immediately after deployment.
/// @dev PRIVATE_KEY must own every configured contract.
contract InitializeDeployment is Script {
    uint256 internal constant DEFAULT_MOCK_USDC_MINT_AMOUNT = 100_000_000e6;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployedOwner = vm.addr(deployerPrivateKey);
        address backendAddress = vm.envAddress("BACKEND_ADDRESS");
        require(backendAddress != address(0), "Invalid backend address");
        address usdcAddress = vm.envAddress("USDC_ADDRESS");
        address optionsAddress = vm.envOr("OPTIONS_AMM_ADDRESS", address(0));
        OneClickPerpDex oneClickPerpDex = OneClickPerpDex(payable(vm.envAddress("ONECLICK_PERPDEX_ADDRESS")));
        bool deployMockUSDC = vm.envOr("DEPLOY_MOCK_USDC", false);
        uint256 mintAmount = vm.envOr("INITIAL_MOCK_USDC_MINT_AMOUNT", DEFAULT_MOCK_USDC_MINT_AMOUNT);

        require(oneClickPerpDex.owner() == deployedOwner, "Deployer is not OneClick owner");
        if (optionsAddress != address(0)) {
            require(optionsAddress.code.length > 0, "No OptionsAMM at target address");
            require(OptionsAMM(optionsAddress).owner() == deployedOwner, "Deployer is not options owner");
        }

        if (deployMockUSDC) {
            require(MockUSDC(usdcAddress).owner() == deployedOwner, "Deployer is not MockUSDC owner");
        }

        vm.startBroadcast(deployerPrivateKey);

        if (deployMockUSDC) {
            MockUSDC(usdcAddress).ownerMint(deployedOwner, mintAmount);
            console.log("MockUSDC minted to deployed owner:");
            console.log(deployedOwner);
            console.log("Amount (6 decimals):", mintAmount);
        } else {
            console.log("Skipping MockUSDC mint: DEPLOY_MOCK_USDC is not true.");
        }

        oneClickPerpDex.authorizeBackend(backendAddress, true);
        console.log("Configured backend authorized for OneClick:");
        console.log(backendAddress);

        if (optionsAddress != address(0)) {
            OptionsAMM(optionsAddress).authorizeBackend(backendAddress, true);
            console.log("Configured backend authorized for OptionsAMM:");
            console.log(backendAddress);
        }

        vm.stopBroadcast();
    }
}

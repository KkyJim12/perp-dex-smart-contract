// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/OptionAMM.sol";
import "../src/opUSDC.sol";

/// @notice Deploys an isolated option vault; it does not share ppUSDC liquidity.
contract DeployOptionAMM is Script {
    function run() external returns (address opUSDCAddress, address optionAMMAddress) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address usdc = vm.envAddress("USDC_ADDRESS");
        address pyth = vm.envAddress("PYTH_ADDRESS");

        vm.startBroadcast(deployerPrivateKey);
        opUSDC shareToken = new opUSDC();
        OptionAMM amm = new OptionAMM(usdc, pyth, address(shareToken));
        shareToken.setOptionAMM(address(amm));
        vm.stopBroadcast();

        return (address(shareToken), address(amm));
    }
}

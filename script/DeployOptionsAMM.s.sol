// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/OptionsAMM.sol";
import "../src/opUSDC.sol";

/// @notice Deploys an isolated options vault; it does not share ppUSDC liquidity.
contract DeployOptionsAMM is Script {
    function run() external returns (address opUSDCAddress, address optionsAMMAddress) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address usdc = vm.envAddress("USDC_ADDRESS");
        address pyth = vm.envAddress("PYTH_ADDRESS");

        vm.startBroadcast(deployerPrivateKey);
        opUSDC shareToken = new opUSDC();
        OptionsAMM amm = new OptionsAMM(usdc, pyth, address(shareToken));
        shareToken.setOptionsAMM(address(amm));
        vm.stopBroadcast();

        return (address(shareToken), address(amm));
    }
}

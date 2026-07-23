// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "lib/forge-std/src/Script.sol";
import "../src/OneClickPerpDex.sol";
import "../src/ocUSDC.sol";
import "../src/ProtocolProxy.sol";
import "./InitialPairConfig.sol";

contract DeployOneClick is Script, InitialPairConfig {
    function run() external returns (address, address) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        // Get USDC address from environment
        address usdcAddress = vm.envAddress("USDC_ADDRESS");

        console.log("Deploying OneClickPerpDex with:");
        console.log("USDC Address:");
        console.log(usdcAddress);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy ocUSDC token
        ocUSDC ocUSDCImplementation = new ocUSDC();
        ocUSDC lpToken = ocUSDC(
            address(
                new ProtocolProxy(
                    address(ocUSDCImplementation),
                    deployer,
                    abi.encodeCall(ocUSDC.initialize, (deployer))
                )
            )
        );
        console.log("");
        console.log("ocUSDC deployed at:");
        console.log(address(lpToken));

        // 2. Deploy OneClickPerpDex
        OneClickPerpDex oneClickImplementation = new OneClickPerpDex(
            usdcAddress,
            address(lpToken)
        );
        OneClickPerpDex oneClick = OneClickPerpDex(
            address(
                new ProtocolProxy(
                    address(oneClickImplementation),
                    deployer,
                    abi.encodeCall(
                        OneClickPerpDex.initialize,
                        (usdcAddress, address(lpToken), deployer)
                    )
                )
            )
        );
        _configureOneClickPerpDex(oneClick);
        console.log("");
        console.log("OneClickPerpDex deployed at:");
        console.log(address(oneClick));

        // 3. Set OneClickPerpDex address in ocUSDC (allows minting/burning)
        lpToken.setOneClickPerpDex(address(oneClick));
        console.log("");
        console.log("ocUSDC configured with OneClickPerpDex address");

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Summary ===");
        console.log("USDC Address:");
        console.log(usdcAddress);
        console.log("ocUSDC Token:");
        console.log(address(lpToken));
        console.log("OneClickPerpDex Contract:");
        console.log(address(oneClick));
        
        console.log("");
        console.log("=== Next Steps ===");
        console.log("1. Authorize backend address:");
        console.log("cast send");
        console.log(address(oneClick));
        console.log('"authorizeBackend(address,bool)" <BACKEND_ADDRESS> true');
        console.log("--rpc-url $RPC_URL --private-key $PRIVATE_KEY");
        console.log("");
        console.log("=== Verification ===");
        console.log("Contracts will be verified automatically if you used --verify flag");
        console.log("Or verify manually with these commands:");
        console.log("");
        
        console.log("ocUSDC:");
        console.log("forge verify-contract");
        console.log(address(lpToken));
        console.log("src/ocUSDC.sol:ocUSDC --watch");
        console.log("");
        
        console.log("OneClickPerpDex:");
        console.log("forge verify-contract");
        console.log(address(oneClick));
        console.log("src/OneClickPerpDex.sol:OneClickPerpDex");
        console.log("--constructor-args $(cast abi-encode 'constructor(address,address)'");
        console.log(usdcAddress);
        console.log(address(lpToken));
        console.log(")");
        console.log("--watch");

        return (address(lpToken), address(oneClick));
    }
}

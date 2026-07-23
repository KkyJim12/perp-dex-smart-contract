// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "lib/forge-std/src/Script.sol";
import "../src/PerpDex.sol";
import "../src/ppUSDC.sol";
import "../src/MockUSDC.sol";
import "../src/ProtocolProxy.sol";
import "./InitialPairConfig.sol";

contract DeployWithppUSDC is Script, InitialPairConfig {
    function run() external returns (address, address, address) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address pythAddress = vm.envAddress("PYTH_ADDRESS");
        
        // Check if we should deploy MockUSDC or use existing USDC
        bool deployMockUSDC = vm.envOr("DEPLOY_MOCK_USDC", true);
        address usdcAddress;

        vm.startBroadcast(deployerPrivateKey);

        // 0. Deploy MockUSDC if needed (for testing)
        if (deployMockUSDC) {
            MockUSDC mockUSDC = new MockUSDC();
            usdcAddress = address(mockUSDC);
            console.log("MockUSDC deployed at:");
            console.log(usdcAddress);
        } else {
            usdcAddress = vm.envAddress("USDC_ADDRESS");
            console.log("Using existing USDC at:");
            console.log(usdcAddress);
        }

        // 1. Deploy ppUSDC token
        ppUSDC ppUSDCImplementation = new ppUSDC();
        ppUSDC lpToken = ppUSDC(
            address(
                new ProtocolProxy(
                    address(ppUSDCImplementation),
                    deployer,
                    abi.encodeCall(ppUSDC.initialize, (deployer))
                )
            )
        );
        console.log("ppUSDC deployed at:");
        console.log(address(lpToken));

        // 2. Deploy PerpDex
        PerpDEX perpDexImplementation = new PerpDEX(
            usdcAddress,
            pythAddress,
            address(lpToken)
        );
        PerpDEX perpDex = PerpDEX(
            address(
                new ProtocolProxy(
                    address(perpDexImplementation),
                    deployer,
                    abi.encodeCall(
                        PerpDEX.initialize,
                        (usdcAddress, pythAddress, address(lpToken), deployer)
                    )
                )
            )
        );
        _configurePerpDex(perpDex);
        console.log("PerpDex deployed at:");
        console.log(address(perpDex));

        // 3. Set PerpDex as authorized minter in ppUSDC (allows minting/burning)
        lpToken.setMinter(address(perpDex), true);
        console.log("ppUSDC configured with PerpDex as authorized minter");

        // 4. Optional: Transfer ppUSDC ownership to a multisig or DAO
        // lpToken.transferOwnership(multisigAddress);

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Summary ===");
        if (deployMockUSDC) {
            console.log("MockUSDC:");
            console.log(usdcAddress);
        } else {
            console.log("USDC Address:");
            console.log(usdcAddress);
        }
        console.log("ppUSDC Token:");
        console.log(address(lpToken));
        console.log("PerpDex Contract:");
        console.log(address(perpDex));
        console.log("Pyth Oracle:");
        console.log(pythAddress);
        
        console.log("");
        console.log("=== Verification ===");
        console.log("Contracts will be verified automatically if you used --verify flag");
        console.log("Or verify manually with these commands:");
        console.log("");
        
        if (deployMockUSDC) {
            console.log("MockUSDC:");
            console.log("forge verify-contract");
            console.log(usdcAddress);
            console.log("src/MockUSDC.sol:MockUSDC --watch");
            console.log("");
        }
        
        console.log("ppUSDC:");
        console.log("forge verify-contract");
        console.log(address(lpToken));
        console.log("src/ppUSDC.sol:ppUSDC --watch");
        console.log("");
        
        console.log("PerpDex:");
        console.log("forge verify-contract");
        console.log(address(perpDex));
        console.log("src/PerpDex.sol:PerpDEX");
        console.log("--constructor-args $(cast abi-encode 'constructor(address,address,address)'");
        console.log(usdcAddress);
        console.log(pythAddress);
        console.log(address(lpToken));
        console.log(")");
        console.log("--watch");
        console.log("");
        
        if (deployMockUSDC) {
            console.log("=== Testing Commands ===");
            console.log("Mint USDC:");
            console.log("cast send");
            console.log(usdcAddress);
            console.log('"mint(address,uint256)" <address> <amount>');
            console.log("--rpc-url $RPC_URL --private-key $PRIVATE_KEY");
        }

        return (usdcAddress, address(lpToken), address(perpDex));
    }
}

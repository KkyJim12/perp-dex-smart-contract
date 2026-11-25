// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DeployPerpDexAtlas} from "../script/DeployPerpDexAtlas.s.sol";
import {PerpDexAtlas} from "../src/PerpDexAtlas.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {ppUSDC} from "../src/ppUSDC.sol";

contract DeployPerpDexAtlasTest is Test {
    DeployPerpDexAtlas internal deployment;
    MockUSDC internal usdc;
    address internal signer;

    function setUp() public {
        deployment = DeployPerpDexAtlas(deployCode("DeployPerpDexAtlas.s.sol:DeployPerpDexAtlas"));
        usdc = new MockUSDC();
        signer = makeAddr("atlas-signer");
        vm.setEnv("PRIVATE_KEY", "1");
        vm.setEnv("USDC_ADDRESS", vm.toString(address(usdc)));
        vm.setEnv("ATLAS_SIGNER", vm.toString(signer));
        vm.setEnv("ATLAS_MAX_PRICE_AGE", "45");
    }

    function testDeployIsolatedVaultAndWireFreshLpToken() public {
        (address lpAddress, address dexAddress) = deployment.run();
        _checkVault(PerpDexAtlas(dexAddress), lpAddress);
        _checkShares(ppUSDC(lpAddress), dexAddress);
    }

    function _checkVault(PerpDexAtlas dex, address lpAddress) internal view {
        assertEq(address(dex.usdc()), address(usdc));
        assertEq(address(dex.ppUSDC()), lpAddress);
        assertEq(dex.atlasSigner(), signer);
        assertEq(dex.maxPriceAge(), 45);
        assertEq(dex.owner(), vm.addr(1));
        assertEq(dex.totalLiquidityRatio(), 0);
    }

    function _checkShares(ppUSDC shares, address dexAddress) internal view {
        assertEq(shares.owner(), vm.addr(1));
        assertTrue(shares.authorizedMinters(dexAddress));
        assertEq(shares.totalSupply(), 0);
    }
}

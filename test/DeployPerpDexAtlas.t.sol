// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DeployPerpDexAtlas} from "../script/DeployPerpDexAtlas.s.sol";
import {PerpDexAtlas} from "../src/PerpDexAtlas.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {ppUSDC} from "../src/ppUSDC.sol";

contract PerpDexAtlasDeploymentFixture is DeployPerpDexAtlas {
    address internal immutable fixtureUSDC;
    address internal immutable fixtureSigner;

    constructor(address usdc, address signer) {
        fixtureUSDC = usdc;
        fixtureSigner = signer;
    }

    function _deploymentConfig() internal view override returns (uint256, address, address, uint256) {
        return (1, fixtureUSDC, fixtureSigner, 5);
    }
}

contract DeployPerpDexAtlasTest is Test {
    DeployPerpDexAtlas internal deployment;
    MockUSDC internal usdc;
    address internal signer;

    function setUp() public {
        usdc = new MockUSDC();
        signer = makeAddr("atlas-signer");
        deployment = DeployPerpDexAtlas(
            deployCode("DeployPerpDexAtlas.t.sol:PerpDexAtlasDeploymentFixture", abi.encode(address(usdc), signer))
        );
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
        assertEq(dex.maxPriceAge(), 5);
        assertEq(dex.owner(), vm.addr(1));
        assertEq(dex.totalLiquidityRatio(), 0);
    }

    function _checkShares(ppUSDC shares, address dexAddress) internal view {
        assertEq(shares.owner(), vm.addr(1));
        assertTrue(shares.authorizedMinters(dexAddress));
        assertEq(shares.totalSupply(), 0);
    }
}

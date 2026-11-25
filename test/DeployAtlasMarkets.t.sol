// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DeployOptionAMMAtlas} from "../script/DeployOptionAMMAtlas.s.sol";
import {DeployPredictionMarketAMMAtlas} from "../script/DeployPredictionMarketAMMAtlas.s.sol";
import {OptionAMMAtlas} from "../src/OptionAMMAtlas.sol";
import {PredictionMarketAMMAtlas} from "../src/PredictionMarketAMMAtlas.sol";
import {AtlasMarketOracle} from "../src/oracle/AtlasMarketOracle.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {opUSDC} from "../src/opUSDC.sol";
import {pmUSDC} from "../src/pmUSDC.sol";

contract OptionAtlasDeploymentFixture is DeployOptionAMMAtlas {
    address internal immutable fixtureUSDC;
    address internal immutable fixtureSigner;

    constructor(address usdc, address signer) {
        fixtureUSDC = usdc;
        fixtureSigner = signer;
    }

    function _deploymentConfig() internal view override returns (uint256, address, address) {
        return (1, fixtureUSDC, fixtureSigner);
    }
}

contract PredictionAtlasDeploymentFixture is DeployPredictionMarketAMMAtlas {
    address internal immutable fixtureUSDC;
    address internal immutable fixtureSigner;

    constructor(address usdc, address signer) {
        fixtureUSDC = usdc;
        fixtureSigner = signer;
    }

    function _deploymentConfig() internal view override returns (uint256, address, address, uint256) {
        return (1, fixtureUSDC, fixtureSigner, 125);
    }
}

contract DeployAtlasMarketsTest is Test {
    address usdc;
    address signer;

    function setUp() public {
        usdc = deployCode("MockUSDC.sol:MockUSDC");
        signer = makeAddr("atlas-market-deployment-signer");
    }

    function testOptionDeploymentWiresFreshLpToIsolatedVault() public {
        DeployOptionAMMAtlas deployment = DeployOptionAMMAtlas(
            deployCode("DeployAtlasMarkets.t.sol:OptionAtlasDeploymentFixture", abi.encode(usdc, signer))
        );
        (address lp, address vault) = deployment.run();
        _checkOracle(vault);
        _checkOption(vault, lp);
    }

    function testPredictionDeploymentCreatesOwnLpAndConfiguredFee() public {
        DeployPredictionMarketAMMAtlas deployment = DeployPredictionMarketAMMAtlas(
            deployCode("DeployAtlasMarkets.t.sol:PredictionAtlasDeploymentFixture", abi.encode(usdc, signer))
        );
        (address lp, address vault) = deployment.run();
        _checkOracle(vault);
        _checkPrediction(vault, lp);
    }

    function _checkOracle(address vault) internal view {
        assertEq(AtlasMarketOracle(vault).owner(), vm.addr(1));
        assertEq(AtlasMarketOracle(vault).atlasSigner(), signer);
    }

    function _checkOption(address vault, address lp) internal view {
        assertEq(address(OptionAMMAtlas(vault).usdc()), usdc);
        assertEq(address(OptionAMMAtlas(vault).opUSDC()), lp);
        assertEq(opUSDC(lp).optionAMM(), vault);
        assertEq(opUSDC(lp).owner(), vm.addr(1));
        assertEq(opUSDC(lp).totalSupply(), 0);
        assertEq(OptionAMMAtlas(vault).pairCount(), 0);
    }

    function _checkPrediction(address vault, address lp) internal view {
        assertEq(address(PredictionMarketAMMAtlas(vault).usdc()), usdc);
        assertEq(address(PredictionMarketAMMAtlas(vault).shareToken()), lp);
        assertEq(PredictionMarketAMMAtlas(vault).feeBps(), 125);
        assertEq(pmUSDC(lp).vault(), vault);
        assertEq(pmUSDC(lp).totalSupply(), 0);
        assertEq(PredictionMarketAMMAtlas(vault).pairCount(), 0);
    }
}

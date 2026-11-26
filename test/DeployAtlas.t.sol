// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DeployAtlas} from "../script/DeployAtlas.s.sol";
import {PerpDexAtlas} from "../src/PerpDexAtlas.sol";
import {OptionAMMAtlas} from "../src/OptionAMMAtlas.sol";
import {PredictionMarketAMMAtlas} from "../src/PredictionMarketAMMAtlas.sol";
import {ppUSDC} from "../src/ppUSDC.sol";
import {opUSDC} from "../src/opUSDC.sol";
import {pmUSDC} from "../src/pmUSDC.sol";
import {MockUSDC} from "../src/MockUSDC.sol";

contract AtlasDeploymentFixture is DeployAtlas {
    Config private fixtureConfig;

    constructor(Config memory config) {
        fixtureConfig = config;
    }

    function _deploymentConfig() internal view override returns (Config memory) {
        return fixtureConfig;
    }
}

contract DeployAtlasTest is Test {
    DeployAtlas.Config private config;

    function setUp() public {
        config = DeployAtlas.Config({
            key: 1,
            usdc: deployCode("MockUSDC.sol:MockUSDC"),
            signer: makeAddr("atlas-signer"),
            maxPriceAge: 5,
            predictionFeeBps: 125
        });
    }

    function _script() private returns (DeployAtlas) {
        return DeployAtlas(deployCode("DeployAtlas.t.sol:AtlasDeploymentFixture", abi.encode(config)));
    }

    function testDeployAllAtlasVaultsWithSeparateWiredLpTokens() public {
        DeployAtlas.Deployment memory deployed = _script().run();
        address owner = vm.addr(config.key);
        PerpDexAtlas perp = PerpDexAtlas(deployed.perp);
        assertEq(perp.owner(), owner);
        assertEq(address(perp.usdc()), config.usdc);
        assertEq(perp.atlasSigner(), config.signer);
        assertEq(perp.maxPriceAge(), config.maxPriceAge);
        assertEq(address(perp.ppUSDC()), deployed.perpShares);
        assertEq(ppUSDC(deployed.perpShares).owner(), owner);
        assertTrue(ppUSDC(deployed.perpShares).authorizedMinters(deployed.perp));

        OptionAMMAtlas option = OptionAMMAtlas(deployed.option);
        assertEq(option.owner(), owner);
        assertEq(address(option.usdc()), config.usdc);
        assertEq(option.atlasSigner(), config.signer);
        assertEq(address(option.opUSDC()), deployed.optionShares);
        assertEq(opUSDC(deployed.optionShares).optionAMM(), deployed.option);
        assertEq(opUSDC(deployed.optionShares).owner(), owner);
        assertEq(option.pairCount(), 0);

        PredictionMarketAMMAtlas prediction = PredictionMarketAMMAtlas(deployed.prediction);
        assertEq(prediction.owner(), owner);
        assertEq(address(prediction.usdc()), config.usdc);
        assertEq(prediction.atlasSigner(), config.signer);
        assertEq(prediction.feeBps(), config.predictionFeeBps);
        assertEq(address(prediction.shareToken()), deployed.predictionShares);
        assertEq(pmUSDC(deployed.predictionShares).vault(), deployed.prediction);
        assertEq(prediction.pairCount(), 0);
        assertEq(prediction.marketCount(), 0);

        assertTrue(deployed.perpShares != deployed.optionShares);
        assertTrue(deployed.perpShares != deployed.predictionShares);
        assertTrue(deployed.optionShares != deployed.predictionShares);
        assertEq(ppUSDC(deployed.perpShares).totalSupply(), 0);
        assertEq(opUSDC(deployed.optionShares).totalSupply(), 0);
        assertEq(pmUSDC(deployed.predictionShares).totalSupply(), 0);
    }

    function testRejectMissingUsdcContractBeforeBroadcast() public {
        config.usdc = address(0x1234);
        DeployAtlas deployment = _script();
        vm.expectRevert("Invalid USDC contract");
        deployment.run();
    }

    function testRejectInvalidSignerBeforeBroadcast() public {
        config.signer = address(0);
        DeployAtlas deployment = _script();
        vm.expectRevert("Invalid Atlas signer");
        deployment.run();
    }

    function testRejectInvalidPriceAgeBeforeBroadcast() public {
        config.maxPriceAge = 0;
        DeployAtlas deployment = _script();
        vm.expectRevert("Invalid max price age");
        deployment.run();
    }

    function testRejectInvalidFeeBeforeBroadcast() public {
        config.predictionFeeBps = 501;
        DeployAtlas deployment = _script();
        vm.expectRevert("Prediction fee exceeds 5%");
        deployment.run();
    }

    function testRejectPriceAgeAboveFiveSecondsBeforeBroadcast() public {
        config.maxPriceAge = 6;
        DeployAtlas deployment = _script();
        vm.expectRevert("Invalid max price age");
        deployment.run();
    }

    function testRejectWrongUsdcDecimalsBeforeBroadcast() public {
        vm.mockCall(config.usdc, abi.encodeWithSignature("decimals()"), abi.encode(uint8(18)));
        DeployAtlas deployment = _script();
        vm.expectRevert("USDC must have 6 decimals");
        deployment.run();
    }
}

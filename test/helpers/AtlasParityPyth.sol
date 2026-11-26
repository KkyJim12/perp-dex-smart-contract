// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PythStructs} from "lib/pyth-sdk-solidity/PythStructs.sol";

/// @dev Initializes the original vaults for quote parity only. Atlas calls use real signatures.
contract AtlasParityPyth {
    function getUpdateFee(bytes[] calldata) external pure returns (uint256) {
        return 0;
    }

    function updatePriceFeeds(bytes[] calldata) external payable {}

    function getPriceNoOlderThan(bytes32, uint256) external view returns (PythStructs.Price memory) {
        return PythStructs.Price(100, 0, 0, block.timestamp);
    }

    function parsePriceFeedUpdatesUnique(bytes[] calldata, bytes32[] calldata ids, uint64 minTime, uint64)
        external
        payable
        returns (PythStructs.PriceFeed[] memory feeds)
    {
        feeds = new PythStructs.PriceFeed[](1);
        PythStructs.Price memory p = PythStructs.Price(100, 0, 0, minTime);
        feeds[0] = PythStructs.PriceFeed(ids[0], p, p);
    }
}

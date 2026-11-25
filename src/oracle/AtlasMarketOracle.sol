// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {Ownable2Step} from "lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {PullOracleConsumerStandard} from "lib/pull-oracle-consumer/src/PullOracleConsumerStandard.sol";

/// @notice Shared signed-price policy for Atlas option and prediction vaults.
/// @dev Atlas extraData must be appended to the individual vault call's calldata.
abstract contract AtlasMarketOracle is Ownable2Step, PullOracleConsumerStandard {
    address public atlasSigner;
    mapping(bytes4 => uint256) public lastSpotTimestamp;
    mapping(bytes4 => uint256) public lastSpotPrice;
    mapping(bytes4 => mapping(uint256 => uint256)) public boundaryPrices;

    event AtlasSignerUpdated(address indexed oldSigner, address indexed newSigner);

    constructor(address signer) Ownable(msg.sender) {
        require(signer != address(0), "Invalid signer");
        atlasSigner = signer;
        emit AtlasSignerUpdated(address(0), signer);
    }

    function setAtlasSigner(address signer) external onlyOwner {
        require(signer != address(0), "Invalid signer");
        emit AtlasSignerUpdated(atlasSigner, signer);
        atlasSigner = signer;
    }

    function _isAuthorizedSigner(address signer) internal view override returns (bool) {
        return signer == atlasSigner;
    }

    /// @dev Boundary settlement must accept historical data; spot age is checked separately.
    function _validateTimestamp(bytes4, uint256 timestamp) internal view override {
        require(timestamp > 0 && timestamp <= block.timestamp, "Invalid oracle timestamp");
    }

    function _atlasSpotPrice(bytes4 feedId, uint64 startTime, uint256 maxAge) internal returns (uint256 price) {
        uint256 timestamp;
        (price, timestamp) = _getVerifiedFeedData(feedId);
        require(price > 0, "Invalid price");
        require(timestamp >= startTime && block.timestamp - timestamp <= maxAge, "Invalid publish time");
        require(timestamp >= lastSpotTimestamp[feedId], "Oracle timestamp regression");
        if (timestamp == lastSpotTimestamp[feedId]) {
            require(price == lastSpotPrice[feedId], "Conflicting spot price");
        }
        lastSpotTimestamp[feedId] = timestamp;
        lastSpotPrice[feedId] = price;
    }

    /// @dev Exact timestamps replace Pyth's first-update proof. Atlas must supply these quotes.
    ///      Cached values enforce consistency across markets sharing a boundary in this vault.
    function _atlasBoundaryPrice(bytes4 feedId, uint64 boundary) internal returns (uint256 price) {
        uint256 timestamp;
        (price, timestamp) = _getVerifiedFeedData(feedId);
        require(price > 0, "Invalid price");
        require(timestamp == boundary, "Wrong boundary timestamp");
        uint256 previous = boundaryPrices[feedId][timestamp];
        require(previous == 0 || previous == price, "Conflicting boundary price");
        boundaryPrices[feedId][timestamp] = price;
    }
}

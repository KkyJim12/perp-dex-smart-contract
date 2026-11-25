// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

/// @dev Real Atlas-format signatures exercise the SDK with fixture keys and feed IDs.
abstract contract AtlasSignedTest is Test {
    uint256 internal constant ATLAS_KEY = 0xa71a5;
    uint256 internal constant OTHER_KEY = 0xbad;
    bytes4 internal constant BTC = 0x00000001;
    bytes4 internal constant ETH = 0x00000002;

    function _payload(bytes4 feed, uint256 price, uint256 timestamp) internal pure returns (bytes memory) {
        return _payloadWithKey(ATLAS_KEY, feed, price, timestamp);
    }

    function _payloadWithKey(uint256 key, bytes4 feed, uint256 price, uint256 timestamp)
        internal
        pure
        returns (bytes memory)
    {
        require(price <= type(uint80).max && timestamp <= type(uint48).max, "Invalid test fixture");
        bytes memory packages = abi.encodePacked(feed, uint80(price), uint48(timestamp));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, keccak256(abi.encodePacked(packages, uint8(1))));
        return abi.encodePacked(packages, uint8(1), r, s, v, uint16(0x7096));
    }

    function _execute(address target, address sender, bytes memory callData, bytes memory payload)
        internal
        returns (bytes memory result)
    {
        vm.prank(sender);
        bool ok;
        (ok, result) = target.call(bytes.concat(callData, payload));
        if (!ok) {
            assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
        }
    }

    function _reject(address target, address sender, bytes memory callData, bytes memory payload, bytes memory expected)
        internal
    {
        vm.prank(sender);
        (bool ok, bytes memory reason) = target.call(bytes.concat(callData, payload));
        assertFalse(ok, "Expected rejection");
        assertEq(reason, expected);
    }

    function _reason(string memory message) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("Error(string)", message);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @notice Reusable ERC-1967-compatible proxy for the protocol contracts.
 * @dev Deploy one instance per implementation. The proxy admin can still call
 *      implementation functions; only upgrade selectors are reserved here.
 */
contract ProtocolProxy {
    bytes32 private constant IMPLEMENTATION_SLOT =
        bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
    bytes32 private constant ADMIN_SLOT =
        bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);

    event Upgraded(address indexed implementation);
    event AdminChanged(address indexed previousAdmin, address indexed newAdmin);

    modifier onlyAdmin() {
        require(msg.sender == _admin(), "Not proxy admin");
        _;
    }

    constructor(address implementation, address admin, bytes memory initData) payable {
        require(admin != address(0), "Invalid admin");
        _setImplementation(implementation);
        _setAdmin(admin);
        if (initData.length > 0) {
            (bool success, bytes memory reason) = implementation.delegatecall(initData);
            if (!success) _revertWith(reason);
        }
    }

    function implementation() external view returns (address) {
        return _implementation();
    }

    function proxyAdmin() external view returns (address) {
        return _admin();
    }

    function changeAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "Invalid admin");
        address oldAdmin = _admin();
        _setAdmin(newAdmin);
        emit AdminChanged(oldAdmin, newAdmin);
    }

    function upgradeTo(address newImplementation) external onlyAdmin {
        _setImplementation(newImplementation);
        emit Upgraded(newImplementation);
    }

    function upgradeToAndCall(
        address newImplementation,
        bytes calldata data
    ) external payable onlyAdmin {
        _setImplementation(newImplementation);
        emit Upgraded(newImplementation);
        (bool success, bytes memory reason) = newImplementation.delegatecall(data);
        if (!success) _revertWith(reason);
    }

    fallback() external payable {
        _delegate(_implementation());
    }

    receive() external payable {}

    function _implementation() internal view returns (address implementation_) {
        bytes32 slot = IMPLEMENTATION_SLOT;
        assembly {
            implementation_ := sload(slot)
        }
    }

    function _admin() internal view returns (address admin_) {
        bytes32 slot = ADMIN_SLOT;
        assembly {
            admin_ := sload(slot)
        }
    }

    function _setImplementation(address newImplementation) internal {
        require(newImplementation.code.length > 0, "Invalid implementation");
        bytes32 slot = IMPLEMENTATION_SLOT;
        assembly {
            sstore(slot, newImplementation)
        }
    }

    function _setAdmin(address newAdmin) internal {
        bytes32 slot = ADMIN_SLOT;
        assembly {
            sstore(slot, newAdmin)
        }
    }

    function _delegate(address implementation_) internal {
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), implementation_, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    function _revertWith(bytes memory reason) private pure {
        assembly {
            revert(add(reason, 32), mload(reason))
        }
    }
}

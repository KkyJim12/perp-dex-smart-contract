// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./UpgradeableERC20.sol";

/**
 * @title ppUSDC (PerpDex Pool USDC)
 * @notice LP token representing shares in the PerpDex liquidity pool
 * @dev Multiple authorized minters (PerpDex contracts) can mint/burn tokens
 */
contract ppUSDC is UpgradeableERC20 {
    mapping(address => bool) public authorizedMinters;
    address public owner;

    event MinterAuthorized(address indexed minter, bool authorized);

    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor() {
        _initialize(msg.sender);
    }

    function initialize(address initialOwner) external {
        _initialize(initialOwner);
    }

    function _initialize(address initialOwner) internal initializer {
        require(initialOwner != address(0), "Invalid address");
        __ERC20_init("PerpDex Pool USDC", "ppUSDC");
        owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);
    }

    modifier onlyMinter() {
        require(authorizedMinters[msg.sender], "Only authorized minters can call");
        _;
    }

    function setMinter(address minter, bool authorized) external onlyOwner {
        require(minter != address(0), "Invalid address");
        authorizedMinters[minter] = authorized;
        emit MinterAuthorized(minter, authorized);
    }

    function mint(address to, uint256 amount) external onlyMinter {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyMinter {
        _burn(from, amount);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    /// @notice Match the 6-decimal USDC collateral used by the pool.
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./UpgradeableERC20.sol";

/**
 * @title ocUSDC (OneClickPerpDex Pool USDC)
 * @notice LP token representing shares in the OneClickPerpDex liquidity pool
 * @dev Only the OneClickPerpDex contract can mint/burn tokens
 */
contract ocUSDC is UpgradeableERC20 {
    address public oneClickPerpDex;
    address public owner;

    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor() {
        _initialize(msg.sender);
    }

    function _initialize(address initialOwner) internal {
        require(initialOwner != address(0), "Invalid address");
        __ERC20_init("OneClickPerpDex Pool USDC", "ocUSDC");
        owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);
    }

    modifier onlyOneClickPerpDex() {
        require(msg.sender == oneClickPerpDex, "Only OneClickPerpDex can call");
        _;
    }

    function setOneClickPerpDex(address _oneClickPerpDex) external onlyOwner {
        require(oneClickPerpDex == address(0), "OneClickPerpDex already set");
        require(_oneClickPerpDex != address(0), "Invalid address");
        oneClickPerpDex = _oneClickPerpDex;
    }

    function mint(address to, uint256 amount) external onlyOneClickPerpDex {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyOneClickPerpDex {
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

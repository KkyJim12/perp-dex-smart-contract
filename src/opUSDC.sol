// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./UpgradeableERC20.sol";

/// @notice Transferable LP share for the Options AMM USDC vault.
/// @dev The AMM is the only account allowed to mint and burn shares.
contract opUSDC is UpgradeableERC20 {
    address public owner;
    address public optionsAMM;

    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);
    event OptionsAMMSet(address indexed optionsAMM);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier onlyOptionsAMM() {
        require(msg.sender == optionsAMM, "Only OptionsAMM can call");
        _;
    }

    constructor() {
        owner = msg.sender;
        __ERC20_init("Options AMM Pool USDC", "opUSDC");
        emit OwnershipTransferred(address(0), msg.sender);
    }

    /// @dev One-time wiring prevents an owner from replacing the vault after LPs join.
    function setOptionsAMM(address amm) external onlyOwner {
        require(optionsAMM == address(0), "OptionsAMM already set");
        require(amm != address(0), "Invalid address");
        optionsAMM = amm;
        emit OptionsAMMSet(amm);
    }

    function mint(address to, uint256 amount) external onlyOptionsAMM {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyOptionsAMM {
        _burn(from, amount);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/// @notice Transferable ownership shares in the prediction market USDC vault.
contract pmUSDC is ERC20 {
    address public immutable vault;

    constructor(address vault_) ERC20("Prediction Market Pool USDC", "pmUSDC") {
        require(vault_ != address(0), "Invalid vault");
        vault = vault_;
    }

    modifier onlyVault() {
        require(msg.sender == vault, "Only vault");
        _;
    }

    function mint(address to, uint256 amount) external onlyVault { _mint(to, amount); }
    function burn(address from, uint256 amount) external onlyVault { _burn(from, amount); }
    function decimals() public pure override returns (uint8) { return 6; }
}

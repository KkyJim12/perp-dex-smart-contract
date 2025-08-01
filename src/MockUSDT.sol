// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract MockUSDT is ERC20 {
    constructor() ERC20("Tether USD", "USDT") {}

    // Anyone can mint tokens for testing
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    // Optional: simulate USDT's 6 decimal places
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

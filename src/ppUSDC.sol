// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";

/**
 * @title ppUSDC (PerpDex Pool USDC)
 * @notice LP token representing shares in the PerpDex liquidity pool
 * @dev Only the PerpDex contract can mint/burn tokens
 */
contract ppUSDC is ERC20, Ownable {
    address public perpDex;

    constructor() ERC20("PerpDex Pool USDC", "ppUSDC") Ownable(msg.sender) {}

    modifier onlyPerpDex() {
        require(msg.sender == perpDex, "Only PerpDex can call");
        _;
    }

    function setPerpDex(address _perpDex) external onlyOwner {
        require(perpDex == address(0), "PerpDex already set");
        require(_perpDex != address(0), "Invalid address");
        perpDex = _perpDex;
    }

    function mint(address to, uint256 amount) external onlyPerpDex {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyPerpDex {
        _burn(from, amount);
    }
}

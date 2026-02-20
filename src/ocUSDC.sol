// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";

/**
 * @title ocUSDC (OneClickPerpDex Pool USDC)
 * @notice LP token representing shares in the OneClickPerpDex liquidity pool
 * @dev Only the OneClickPerpDex contract can mint/burn tokens
 */
contract ocUSDC is ERC20, Ownable {
    address public oneClickPerpDex;

    constructor() ERC20("OneClickPerpDex Pool USDC", "ocUSDC") Ownable(msg.sender) {}

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
}

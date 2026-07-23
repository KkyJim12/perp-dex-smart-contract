// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";

/**
 * @title ppUSDC (PerpDex Pool USDC)
 * @notice LP token representing shares in the PerpDex liquidity pool
 * @dev Multiple authorized minters (PerpDex contracts) can mint/burn tokens
 */
contract ppUSDC is ERC20, Ownable {
    mapping(address => bool) public authorizedMinters;

    event MinterAuthorized(address indexed minter, bool authorized);

    constructor() ERC20("PerpDex Pool USDC", "ppUSDC") Ownable(msg.sender) {}

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

    /// @notice Match the 6-decimal USDC collateral used by the pool.
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

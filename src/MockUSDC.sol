// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";

/// @notice Test USDC with a one-time faucet claim for each wallet.
contract MockUSDC is ERC20, Ownable {
    /// @notice Amount each wallet can claim once: 1,000 USDC at 6 decimals.
    uint256 public constant USER_MINT_AMOUNT = 1_000e6;

    mapping(address => bool) public hasMinted;
    bool public userMintEnabled = true;

    event UserMinted(address indexed account, uint256 amount);
    event UserMintEnabledUpdated(bool enabled);

    constructor() ERC20("USD Coin", "USDC") Ownable(msg.sender) {}

    /// @notice Mint an arbitrary amount. Restricted to the contract owner.
    function ownerMint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /// @notice Enable or disable one-time user faucet claims.
    function setUserMintEnabled(bool enabled) external onlyOwner {
        userMintEnabled = enabled;
        emit UserMintEnabledUpdated(enabled);
    }

    /// @notice Claim the fixed faucet allocation once per wallet.
    function mint() external {
        require(userMintEnabled, "User mint disabled");
        require(!hasMinted[msg.sender], "USDC already claimed");

        hasMinted[msg.sender] = true;
        _mint(msg.sender, USER_MINT_AMOUNT);

        emit UserMinted(msg.sender, USER_MINT_AMOUNT);
    }

    // USDC uses 6 decimal places
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "lib/pyth-sdk-solidity/PythStructs.sol";
import "lib/pyth-sdk-solidity/IPyth.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract PerpDEX {
    IPyth public pyth;
    ERC20 public usdt;

    struct Position {
        bytes32 id;
        bool isLong;
        uint256 margin;
        uint256 size;
        uint256 entryPrice;
    }

    mapping(address => Position) public positions;

    constructor(address _usdt, address _pyth) {
        usdt = ERC20(_usdt);
        pyth = IPyth(_pyth);
    }

    event OpenPosition(
        bytes32 id,
        bool isLong,
        uint256 margin,
        uint256 size,
        uint256 entryPrice
    );

    event ClosePosition(
        bytes32 id,
        bool isLong,
        uint256 margin,
        uint256 size,
        uint256 entryPrice,
        uint256 payout
    );

    function depositCollateral(uint256 _amount) external {
        require(
            usdt.transferFrom(msg.sender, address(this), _amount),
            "Transfer failed"
        );
    }

    function openPosition(
        bool _isLong,
        uint256 _margin,
        uint256 _size,
        bytes32 priceId // BTC/USD price feed ID
    ) external {
        // 1. Transfer collateral from user to contract
        require(
            usdt.transferFrom(msg.sender, address(this), _margin),
            "USDT transfer failed"
        );

        // 2. Read the price
        PythStructs.Price memory price = pyth.getPrice(priceId);
        require(price.price > 0, "Invalid price");

        // 3. Save the position
        positions[msg.sender] = Position({
            id: keccak256(
                abi.encodePacked(msg.sender, block.timestamp, block.number)
            ),
            isLong: _isLong,
            margin: _margin,
            size: _size,
            entryPrice: toUint(price.price)
        });

        emit OpenPosition(
            positions[msg.sender].id,
            positions[msg.sender].isLong,
            positions[msg.sender].margin,
            positions[msg.sender].size,
            positions[msg.sender].entryPrice
        );
    }

    function closePosition(
        bytes[] calldata priceUpdateData,
        bytes32 priceId
    ) external {
        Position storage pos = positions[msg.sender];
        require(pos.size > 0, "No open position");

        // Update and read price
        pyth.updatePriceFeeds(priceUpdateData);
        PythStructs.Price memory price = pyth.getPrice(priceId);

        uint256 pnl;
        if (pos.isLong) {
            pnl =
                (pos.size * (toUint(price.price) - pos.entryPrice)) /
                pos.entryPrice;
        } else {
            pnl =
                (pos.size * (pos.entryPrice - toUint(price.price))) /
                pos.entryPrice;
        }

        uint256 payout = pos.margin + pnl;

        // Settle the trade (send funds, update storage, etc.)
        delete positions[msg.sender];

        require(usdt.transfer(msg.sender, payout), "USDT transfer failed");

        emit ClosePosition(
            positions[msg.sender].id,
            positions[msg.sender].isLong,
            positions[msg.sender].margin,
            positions[msg.sender].size,
            positions[msg.sender].entryPrice,
            payout
        );
    }

    function toUint(int64 x) internal pure returns (uint256) {
        require(x >= 0, "Negative int64 can't convert to uint");
        return uint256(int256(x));
    }
}

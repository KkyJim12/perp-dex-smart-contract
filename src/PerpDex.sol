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
        string pairs;
        bool isLong;
        uint256 margin;
        uint256 size;
        uint256 entryPrice;
        bytes32 pythTokenId;
        bool isClose;
    }

    mapping(address => Position[]) public positions;

    constructor(address _usdt, address _pyth) {
        usdt = ERC20(_usdt);
        pyth = IPyth(_pyth);
    }

    event OpenPosition(
        bytes32 id,
        string pairs,
        bool isLong,
        uint256 margin,
        uint256 size,
        uint256 entryPrice
    );

    event ClosePosition(bytes32 id, uint256 closePrice, uint256 payout);

    function openPosition(
        string calldata _pairs,
        bool _isLong,
        uint256 _margin,
        uint256 _size,
        bytes32 _priceId // Pyth Token Id
    ) external {
        // Transfer collateral from user to contract
        require(
            usdt.transferFrom(msg.sender, address(this), _margin),
            "USDT transfer failed"
        );

        // Read the price
        PythStructs.Price memory token = pyth.getPrice(_priceId);
        require(token.price > 0, "Invalid price");

        bytes32 id = keccak256(
            abi.encodePacked(msg.sender, block.timestamp, block.number)
        );

        // Save the position
        positions[msg.sender].push(
            Position(
                id,
                _pairs,
                _isLong,
                _margin,
                _size,
                toUint(token.price),
                _priceId,
                false
            )
        );

        // Emit event to store on backend
        emit OpenPosition(
            id,
            _pairs,
            _isLong,
            _margin,
            _size,
            toUint(token.price)
        );
    }

    function closePosition(bytes32 _positionId) external {
        // Find position
        for (uint i = 0; i < positions[msg.sender].length; i++) {
            if (
                positions[msg.sender][i].isClose == false &&
                positions[msg.sender][i].id == _positionId
            ) {
                PythStructs.Price memory token = pyth.getPrice(
                    positions[msg.sender][i].pythTokenId
                );
                require(token.price > 0, "Invalid price");

                uint256 pnl;

                if (positions[msg.sender][i].isLong) {
                    pnl =
                        (positions[msg.sender][i].size *
                            (toUint(token.price) -
                                positions[msg.sender][i].entryPrice)) /
                        positions[msg.sender][i].entryPrice;
                } else {
                    pnl =
                        (positions[msg.sender][i].size *
                            (positions[msg.sender][i].entryPrice -
                                toUint(token.price))) /
                        positions[msg.sender][i].entryPrice;
                }

                uint256 payout = positions[msg.sender][i].margin + pnl;

                require(
                    usdt.transfer(msg.sender, payout),
                    "USDT transfer failed"
                );

                // Settle the trade (send funds, update storage, etc.)
                positions[msg.sender][i].isClose = true;

                // Emit event to store on backend
                emit ClosePosition(_positionId, toUint(token.price), payout);
            }
        }
    }

    function toUint(int64 x) internal pure returns (uint256) {
        require(x >= 0, "Negative int64 can't convert to uint");
        return uint256(int256(x));
    }
}

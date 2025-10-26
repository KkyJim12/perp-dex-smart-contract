// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "lib/pyth-sdk-solidity/PythStructs.sol";
import "lib/pyth-sdk-solidity/IPyth.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract PerpDEX {
    IPyth public immutable pyth;
    ERC20 public immutable usdt;
    uint256 public constant FEE_RATIO = 5e14; // 0.05%

    struct Position {
        bytes32 id;
        string pairs;
        bool isLong;
        uint256 margin;
        uint256 leverage;
        uint256 size;
        uint256 entryPrice;
        bytes32 pythTokenId;
        bool isClosed;
        uint256 closePrice;
        uint256 payout;
        uint256 liquidationPrice;
        uint256 fees;
    }

    mapping(address => Position[]) public positions;
    mapping(address => string) public username;

    event OpenPosition(
        bytes32 indexed id,
        address indexed user,
        string pairs,
        bool isLong,
        uint256 margin,
        uint256 leverage,
        uint256 size,
        uint256 entryPrice,
        bytes32 pythTokenId,
        uint256 liquidationPrice,
        uint256 fees
    );

    event ClosePosition(
        bytes32 indexed id,
        address indexed user,
        uint256 closePrice,
        uint256 payout
    );

    event RegisterUser(address indexed userAddress, string username);

    constructor(address _usdt, address _pyth) {
        require(_usdt != address(0) && _pyth != address(0), "Invalid address");
        usdt = ERC20(_usdt);
        pyth = IPyth(_pyth);
    }

    function registerUser(string calldata _username) external {
        require(bytes(_username).length > 0, "Username cannot be empty");
        require(
            bytes(username[msg.sender]).length == 0,
            "User already registered"
        );
        username[msg.sender] = _username;
        emit RegisterUser(msg.sender, _username);
    }

    function openPosition(
        string calldata pairs,
        bool isLong,
        uint256 margin,
        uint256 leverage,
        bytes32 pythTokenId
    ) external {
        require(margin > 0 && leverage > 0, "Invalid margin or leverage");
        require(
            usdt.transferFrom(msg.sender, address(this), margin),
            "USDT transfer failed"
        );

        uint256 fees = (margin * leverage * FEE_RATIO) / 1e18;
        uint256 netMargin = margin - fees;
        uint256 netSize = netMargin * leverage;

        _finalizeOpenPosition(
            pairs,
            isLong,
            netMargin,
            leverage,
            netSize,
            pythTokenId,
            fees
        );
    }

    function _finalizeOpenPosition(
        string calldata pairs,
        bool isLong,
        uint256 netMargin,
        uint256 leverage,
        uint256 netSize,
        bytes32 pythTokenId,
        uint256 fees
    ) internal {
        PythStructs.Price memory token = pyth.getPrice(pythTokenId);
        require(token.price > 0, "Invalid price");

        uint256 entryPrice = toUint(token.price);
        uint256 liquidationPrice = calculateLiquidationPrice(
            entryPrice,
            netSize,
            netMargin,
            isLong
        );
        bytes32 id = keccak256(
            abi.encodePacked(msg.sender, block.timestamp, block.number)
        );

        positions[msg.sender].push(
            Position({
                id: id,
                pairs: pairs,
                isLong: isLong,
                margin: netMargin,
                leverage: leverage,
                size: netSize,
                entryPrice: entryPrice,
                pythTokenId: pythTokenId,
                isClosed: false,
                closePrice: 0,
                payout: 0,
                liquidationPrice: liquidationPrice,
                fees: fees
            })
        );

        emit OpenPosition(
            id,
            msg.sender,
            pairs,
            isLong,
            netMargin,
            leverage,
            netSize,
            entryPrice,
            pythTokenId,
            liquidationPrice,
            fees
        );
    }

    function closePosition(bytes32 positionId) external {
        Position[] storage userPositions = positions[msg.sender];
        uint256 len = userPositions.length;

        for (uint256 i = 0; i < len; i++) {
            Position storage pos = userPositions[i];
            if (!pos.isClosed && pos.id == positionId) {
                PythStructs.Price memory token = pyth.getPrice(pos.pythTokenId);
                require(token.price > 0, "Invalid price");

                uint256 currentPrice = toUint(token.price);
                int256 pnl;

                if (pos.isLong) {
                    pnl =
                        (int256(pos.size) *
                            (int256(currentPrice) - int256(pos.entryPrice))) /
                        int256(pos.entryPrice);
                } else {
                    pnl =
                        (int256(pos.size) *
                            (int256(pos.entryPrice) - int256(currentPrice))) /
                        int256(pos.entryPrice);
                }

                int256 rawPayout = int256(pos.margin) + pnl;
                uint256 payout = rawPayout > 0 ? uint256(rawPayout) : 0;

                require(
                    usdt.transfer(msg.sender, payout),
                    "USDT payout failed"
                );

                pos.isClosed = true;
                pos.closePrice = currentPrice;
                pos.payout = payout;

                emit ClosePosition(
                    positionId,
                    msg.sender,
                    currentPrice,
                    payout
                );
                return;
            }
        }

        revert("Position not found or already closed");
    }

    function calculateLiquidationPrice(
        uint256 entryPrice,
        uint256 size,
        uint256 margin,
        bool isLong
    ) internal pure returns (uint256) {
        uint256 priceChange = (entryPrice * margin) / size;
        return isLong ? entryPrice - priceChange : entryPrice + priceChange;
    }

    function toUint(int64 x) internal pure returns (uint256) {
        require(x >= 0, "Negative price");
        return uint256(int256(x));
    }
}

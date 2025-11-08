// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "lib/pyth-sdk-solidity/PythStructs.sol";
import "lib/pyth-sdk-solidity/IPyth.sol";

contract PerpDEX is ReentrancyGuard {
    using SafeERC20 for ERC20;

    IPyth public immutable pyth;
    ERC20 public immutable usdt;
    address public owner;

    // ---------- Constants ----------
    uint256 public constant ONE = 1e18;
    uint256 public constant FEE_RATIO = 5e14; // 0.05%
    uint256 public constant SPREAD_BPS = 5; // 0.05%
    uint256 public constant MAINTENANCE_MARGIN_RATIO = 10e16; // 10%
    uint256 public constant LIQUIDATION_REWARD_RATIO = 2e16; // 2%

    // ---------- Staking Pool ----------
    uint256 public totalStaked;
    mapping(address => uint256) public stakedBalance;

    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event PoolUpdated(uint256 totalStaked, string reason, int256 pnlImpact);

    // ---------- Data ----------
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
        int256 fundingEntry;
        uint256 takeProfit;
        uint256 stopLoss;
    }

    struct PairFunding {
        uint256 oiLong;
        uint256 oiShort;
        int256 growth;
        uint256 lastUpdate;
    }

    struct PairInfo {
        string name;
        bytes32 pythTokenId;
        bool active;
    }

    // ---------- Storage ----------
    mapping(address => Position[]) public positions;
    mapping(string => PairFunding) public pairFunding;
    mapping(string => PairInfo) public pairInfo;
    PairInfo[] public allPairs;

    // ---------- Events ----------
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
        uint256 payout,
        uint256 closeFee
    );
    event TpSlSet(
        address indexed user,
        bytes32 indexed positionId,
        uint256 takeProfit,
        uint256 stopLoss
    );
    event TpSlTriggered(
        address indexed keeper,
        address indexed user,
        bytes32 indexed positionId,
        string triggerType,
        uint256 triggerPrice
    );
    event Liquidated(
        address indexed keeper,
        address indexed user,
        bytes32 indexed positionId,
        string pairs,
        uint256 markPrice,
        uint256 timestamp
    );
    event OwnershipTransferred(
        address indexed oldOwner,
        address indexed newOwner
    );

    // ---------- Ownership ----------
    modifier onlyOwner() {
        require(msg.sender == owner, "Not admin");
        _;
    }

    constructor(address _usdt, address _pyth) {
        require(_usdt != address(0) && _pyth != address(0), "Invalid address");
        usdt = ERC20(_usdt);
        pyth = IPyth(_pyth);
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
        _addInitialPairs();
    }

    // ---------- Pair Management ----------
    function _addInitialPairs() internal {
        addPairInternal(
            "BTC_USD",
            0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43
        );
        addPairInternal(
            "ETH_USD",
            0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace
        );
        addPairInternal(
            "SOL_USD",
            0xef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d
        );
        addPairInternal(
            "HYPE_USD",
            0x9ff5a5b3b76e62ab1452a65b0421d48a692f6a3d0d0970c8e1f9825a12b2b2cc
        );
        addPairInternal(
            "XRP_USD",
            0x2f17f49c4eae5b8af67b0aaf76e95a85c3984ecf4de8b4d54d3626455cfd0dc3
        );
        addPairInternal(
            "ZRO_USD",
            0x8968f2c9bfae7cb9a531fb9f84d2cf2e9d89e3f4a45b15b18a2b8afc573dc23e
        );
        addPairInternal(
            "DOGE_USD",
            0x971e9b5a0c09b6b8a38e05eec346d4c2c9a017781ae3a1f3bda14e9a25d20f64
        );
    }

    function addPairInternal(
        string memory pairs,
        bytes32 pythTokenId
    ) internal {
        pairInfo[pairs] = PairInfo(pairs, pythTokenId, true);
        allPairs.push(pairInfo[pairs]);
    }

    // ---------- Staking ----------
    function stake(uint256 amount) external nonReentrant {
        require(amount > 0, "Zero amount");
        usdt.safeTransferFrom(msg.sender, address(this), amount);
        stakedBalance[msg.sender] += amount;
        totalStaked += amount;
        emit Staked(msg.sender, amount);
    }

    function unstake(uint256 amount) external nonReentrant {
        require(amount > 0, "Zero amount");
        require(stakedBalance[msg.sender] >= amount, "Not enough staked");
        require(totalStaked >= amount, "Pool low");
        stakedBalance[msg.sender] -= amount;
        totalStaked -= amount;
        usdt.safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    // ---------- Core: Pool PnL Integration ----------
    function _applyPnLToPool(int256 pnl) internal {
        if (pnl > 0) {
            uint256 loss = uint256(pnl);
            require(totalStaked >= loss, "Pool depleted");
            totalStaked -= loss;
            emit PoolUpdated(totalStaked, "TraderWin", pnl);
        } else if (pnl < 0) {
            uint256 gain = uint256(-pnl);
            totalStaked += gain;
            emit PoolUpdated(totalStaked, "TraderLoss", pnl);
        }
    }

    // ---------- Open Position ----------
    function openPosition(
        string calldata pairs,
        bool isLong,
        uint256 margin,
        uint256 leverage
    ) external nonReentrant {
        require(margin > 0 && leverage > 0, "Bad params");
        PairInfo storage info = pairInfo[pairs];
        require(info.active, "Pair inactive");
        usdt.safeTransferFrom(msg.sender, address(this), margin);

        uint256 fees = (margin * leverage * FEE_RATIO) / ONE;
        uint256 netMargin = margin - fees;
        uint256 netSize = netMargin * leverage;

        PythStructs.Price memory token = pyth.getPrice(info.pythTokenId);
        require(token.price > 0, "Invalid price");

        uint256 oraclePrice = _toUintPrice1e8(token);
        uint256 entryPrice = applySpread(oraclePrice, isLong, true);
        uint256 liq = calculateLiquidationPrice(
            entryPrice,
            netSize,
            netMargin,
            isLong
        );

        bytes32 id = keccak256(
            abi.encodePacked(msg.sender, pairs, block.timestamp, block.number)
        );
        PairFunding storage pf = pairFunding[pairs];

        positions[msg.sender].push(
            Position({
                id: id,
                pairs: pairs,
                isLong: isLong,
                margin: netMargin,
                leverage: leverage,
                size: netSize,
                entryPrice: entryPrice,
                pythTokenId: info.pythTokenId,
                isClosed: false,
                closePrice: 0,
                payout: 0,
                liquidationPrice: liq,
                fees: fees,
                fundingEntry: pf.growth,
                takeProfit: 0,
                stopLoss: 0
            })
        );

        if (isLong) pf.oiLong += netSize;
        else pf.oiShort += netSize;

        emit OpenPosition(
            id,
            msg.sender,
            pairs,
            isLong,
            netMargin,
            leverage,
            netSize,
            entryPrice,
            info.pythTokenId,
            liq,
            fees
        );
    }

    // ---------- TP/SL ----------
    function setTpSl(
        bytes32 positionId,
        uint256 newTp,
        uint256 newSl
    ) external nonReentrant {
        Position storage pos = _getOpenPositionOf(msg.sender, positionId);
        if (newTp > 0) {
            if (pos.isLong) require(newTp > pos.entryPrice, "TP must > entry");
            else require(newTp < pos.entryPrice, "TP must < entry");
            pos.takeProfit = newTp;
        }
        if (newSl > 0) {
            if (pos.isLong) require(newSl < pos.entryPrice, "SL must < entry");
            else require(newSl > pos.entryPrice, "SL must > entry");
            pos.stopLoss = newSl;
        }
        emit TpSlSet(msg.sender, positionId, pos.takeProfit, pos.stopLoss);
    }

    // ---------- Liquidate ----------
    function liquidate(address user, bytes32 positionId) external nonReentrant {
        Position storage pos = _getOpenPositionOf(user, positionId);
        PythStructs.Price memory token = pyth.getPrice(pos.pythTokenId);
        uint256 mark = _toUintPrice1e8(token);

        bool hit = pos.isLong
            ? mark <= pos.liquidationPrice
            : mark >= pos.liquidationPrice;
        require(hit, "Not liquidatable");

        // Compute PnL
        int256 pnl = pos.isLong
            ? (int256(pos.size) * (int256(mark) - int256(pos.entryPrice))) /
                int256(pos.entryPrice)
            : (int256(pos.size) * (int256(pos.entryPrice) - int256(mark))) /
                int256(pos.entryPrice);

        int256 rawPayout = int256(pos.margin) + pnl;
        if (rawPayout < 0) rawPayout = 0;

        uint256 reward = (pos.margin * LIQUIDATION_REWARD_RATIO) / ONE;
        if (reward > 0) usdt.safeTransfer(msg.sender, reward);

        _applyPnLToPool(pnl);

        pos.isClosed = true;
        pos.closePrice = mark;
        pos.payout = 0; // trader gets nothing

        emit Liquidated(
            msg.sender,
            user,
            positionId,
            pos.pairs,
            mark,
            block.timestamp
        );
    }

    // ---------- Helpers ----------
    function _getOpenPositionOf(
        address user,
        bytes32 positionId
    ) internal view returns (Position storage) {
        Position[] storage arr = positions[user];
        for (uint256 i; i < arr.length; i++) {
            if (!arr[i].isClosed && arr[i].id == positionId) return arr[i];
        }
        revert("Position not found/already closed");
    }

    function applySpread(
        uint256 price,
        bool isLong,
        bool isEntry
    ) internal pure returns (uint256) {
        if (!isEntry) return price;
        uint256 spread = (price * SPREAD_BPS) / 10000;
        return isLong ? price + spread : price - spread;
    }

    function calculateLiquidationPrice(
        uint256 entryPrice,
        uint256 size,
        uint256 margin,
        bool isLong
    ) internal pure returns (uint256) {
        uint256 maintMargin = (margin * MAINTENANCE_MARGIN_RATIO) / ONE;
        uint256 effectiveMargin = margin - maintMargin;
        uint256 priceChange = (entryPrice * effectiveMargin) / size;
        return isLong ? entryPrice - priceChange : entryPrice + priceChange;
    }

    function _toUintPrice1e8(
        PythStructs.Price memory p
    ) internal pure returns (uint256) {
        require(p.price > 0, "Bad price");
        int256 v = int256(p.price);
        int32 expo = p.expo;
        int32 diff = -8 - expo;
        if (diff > 0) {
            for (int32 i; i < diff; i++) v *= 10;
        } else if (diff < 0) {
            for (int32 i; i < -diff; i++) v /= 10;
        }
        return uint256(v);
    }
}

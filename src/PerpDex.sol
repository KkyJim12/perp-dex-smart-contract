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

    // ---------- Usernames ----------
    mapping(address => string) public usernames;
    mapping(string => address) public usernameToAddress;

    event UsernameRegistered(address indexed user, string username);
    event UsernameChanged(
        address indexed user,
        string oldUsername,
        string newUsername
    );

    function registerUsername(string calldata name) external {
        require(
            bytes(name).length >= 3 && bytes(name).length <= 32,
            "Bad length"
        );
        require(bytes(usernames[msg.sender]).length == 0, "Already registered");
        require(usernameToAddress[name] == address(0), "Name taken");

        usernames[msg.sender] = name;
        usernameToAddress[name] = msg.sender;

        emit UsernameRegistered(msg.sender, name);
    }

    function changeUsername(string calldata newName) external {
        string memory current = usernames[msg.sender];
        require(bytes(current).length > 0, "Not registered");
        require(
            bytes(newName).length >= 3 && bytes(newName).length <= 32,
            "Bad length"
        );
        require(usernameToAddress[newName] == address(0), "Name taken");

        // Release old name
        delete usernameToAddress[current];

        // Assign new name
        usernames[msg.sender] = newName;
        usernameToAddress[newName] = msg.sender;

        emit UsernameChanged(msg.sender, current, newName);
    }

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
        uint256 fees,
        uint256 takeProfit,
        uint256 stopLoss
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

    // ---------- Core: Pool PnL ----------
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
        uint256 leverage,
        uint256 takeProfit,
        uint256 stopLoss
    ) external nonReentrant {
        require(margin > 0 && leverage > 0, "Bad params");
        PairInfo storage info = pairInfo[pairs];
        require(info.active, "Pair inactive");
        usdt.safeTransferFrom(msg.sender, address(this), margin);

        uint256 fees = (margin * leverage * FEE_RATIO) / ONE;
        uint256 netMargin = margin - fees;
        uint256 netSize = netMargin * leverage;

        // ---------- 1️⃣ Get current oracle price ----------
        PythStructs.Price memory token = pyth.getPrice(info.pythTokenId);
        require(token.price > 0, "Invalid price");
        uint256 oraclePrice = _toUintPrice1e8(token);
        uint256 entryPrice = applySpread(oraclePrice, isLong, true);

        // ---------- 2️⃣ Validate TP/SL vs current oracle ----------
        if (takeProfit > 0) {
            if (isLong) {
                require(takeProfit > oraclePrice, "Invalid Long TP");
            } else {
                require(takeProfit < oraclePrice, "Invalid Short TP");
            }
        }
        if (stopLoss > 0) {
            if (isLong) {
                require(stopLoss < oraclePrice, "Invalid Long SL");
            } else {
                require(stopLoss > oraclePrice, "Invalid Short SL");
            }
        }

        // ---------- 3️⃣ Calculate liquidation price ----------
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
                takeProfit: takeProfit,
                stopLoss: stopLoss
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
            fees,
            takeProfit,
            stopLoss
        );
    }

    // ---------- Close Position ----------
    function closePosition(bytes32 positionId) external nonReentrant {
        Position storage pos = _getOpenPositionOf(msg.sender, positionId);
        PythStructs.Price memory token = pyth.getPrice(pos.pythTokenId);
        uint256 mark = _toUintPrice1e8(token);

        uint256 closePrice = mark; // no spread
        int256 pnl = pos.isLong
            ? (int256(pos.size) *
                (int256(closePrice) - int256(pos.entryPrice))) /
                int256(pos.entryPrice)
            : (int256(pos.size) *
                (int256(pos.entryPrice) - int256(closePrice))) /
                int256(pos.entryPrice);

        int256 rawPayout = int256(pos.margin) + pnl;
        if (rawPayout < 0) rawPayout = 0;

        uint256 payout = uint256(rawPayout);
        uint256 closeFee = (payout * FEE_RATIO) / ONE;
        uint256 netPayout = payout - closeFee;

        _applyPnLToPool(pnl);
        usdt.safeTransfer(msg.sender, netPayout);

        pos.isClosed = true;
        pos.closePrice = closePrice;
        pos.payout = netPayout;

        emit ClosePosition(
            positionId,
            msg.sender,
            closePrice,
            netPayout,
            closeFee
        );
    }

    function setTpSl(
        bytes32 positionId,
        uint256 newTp,
        uint256 newSl
    ) external nonReentrant {
        Position storage pos = _getOpenPositionOf(msg.sender, positionId);
        require(!pos.isClosed, "Position closed");

        // ---------- 1️⃣ Get latest Pyth oracle price ----------
        PythStructs.Price memory token = pyth.getPrice(pos.pythTokenId);
        uint256 currentPrice = _toUintPrice1e8(token);
        require(currentPrice > 0, "Invalid oracle price");

        // ---------- 2️⃣ Validate take profit ----------
        if (newTp > 0) {
            if (pos.isLong) {
                require(
                    newTp > currentPrice,
                    "Long TP must be above current price"
                );
            } else {
                require(
                    newTp < currentPrice,
                    "Short TP must be below current price"
                );
            }
            pos.takeProfit = newTp;
        }

        // ---------- 3️⃣ Validate stop loss ----------
        if (newSl > 0) {
            if (pos.isLong) {
                require(
                    newSl < currentPrice,
                    "Long SL must be below current price"
                );
            } else {
                require(
                    newSl > currentPrice,
                    "Short SL must be above current price"
                );
            }
            pos.stopLoss = newSl;
        }

        // ---------- 4️⃣ Emit event ----------
        emit TpSlSet(msg.sender, positionId, pos.takeProfit, pos.stopLoss);
    }

    function triggerTpSl(
        address user,
        bytes32 positionId
    ) external nonReentrant {
        Position storage pos = _getOpenPositionOf(user, positionId);
        require(!pos.isClosed, "Already closed");

        // ---------- 1️⃣ Get latest oracle price ----------
        PythStructs.Price memory token = pyth.getPrice(pos.pythTokenId);
        uint256 mark = _toUintPrice1e8(token);

        bool hitTp = false;
        bool hitSl = false;
        uint256 triggerPrice = 0;
        string memory triggerType;

        if (pos.isLong) {
            if (pos.takeProfit > 0 && mark >= pos.takeProfit) {
                hitTp = true;
                triggerPrice = pos.takeProfit;
                triggerType = "TakeProfit";
            } else if (pos.stopLoss > 0 && mark <= pos.stopLoss) {
                hitSl = true;
                triggerPrice = pos.stopLoss;
                triggerType = "StopLoss";
            }
        } else {
            if (pos.takeProfit > 0 && mark <= pos.takeProfit) {
                hitTp = true;
                triggerPrice = pos.takeProfit;
                triggerType = "TakeProfit";
            } else if (pos.stopLoss > 0 && mark >= pos.stopLoss) {
                hitSl = true;
                triggerPrice = pos.stopLoss;
                triggerType = "StopLoss";
            }
        }

        require(hitTp || hitSl, "No TP/SL hit");

        // ---------- 2️⃣ Calculate PnL based on *exact TP/SL price* ----------
        uint256 closePrice = triggerPrice; // Use the exact target price
        int256 pnl = pos.isLong
            ? (int256(pos.size) *
                (int256(closePrice) - int256(pos.entryPrice))) /
                int256(pos.entryPrice)
            : (int256(pos.size) *
                (int256(pos.entryPrice) - int256(closePrice))) /
                int256(pos.entryPrice);

        // ---------- 3️⃣ Compute payout and fees ----------
        int256 rawPayout = int256(pos.margin) + pnl;
        if (rawPayout < 0) rawPayout = 0;

        uint256 payout = uint256(rawPayout);
        uint256 closeFee = (payout * FEE_RATIO) / ONE;
        uint256 netPayout = payout - closeFee;

        // ---------- 4️⃣ Apply to pool and pay trader ----------
        _applyPnLToPool(pnl);
        usdt.safeTransfer(user, netPayout);

        // ---------- 5️⃣ Mark position closed ----------
        pos.isClosed = true;
        pos.closePrice = closePrice;
        pos.payout = netPayout;

        emit TpSlTriggered(
            msg.sender,
            user,
            positionId,
            triggerType,
            closePrice
        );
    }

    function triggerLiquidation(
        address user,
        bytes32 positionId
    ) external nonReentrant {
        Position storage pos = _getOpenPositionOf(user, positionId);
        require(!pos.isClosed, "Already closed");

        // ---------- 1️⃣ Get latest oracle price ----------
        PythStructs.Price memory token = pyth.getPrice(pos.pythTokenId);
        uint256 mark = _toUintPrice1e8(token);
        require(mark > 0, "Invalid oracle price");

        bool canLiq = (pos.isLong && mark <= pos.liquidationPrice) ||
            (!pos.isLong && mark >= pos.liquidationPrice);
        require(canLiq, "Not liquidatable");

        // ---------- 2️⃣ Calculate payout (losing position) ----------
        uint256 closePrice = mark;
        int256 pnl = pos.isLong
            ? (int256(pos.size) *
                (int256(closePrice) - int256(pos.entryPrice))) /
                int256(pos.entryPrice)
            : (int256(pos.size) *
                (int256(pos.entryPrice) - int256(closePrice))) /
                int256(pos.entryPrice);

        int256 rawPayout = int256(pos.margin) + pnl;
        if (rawPayout < 0) rawPayout = 0;

        uint256 payout = uint256(rawPayout);
        uint256 keeperReward = (payout * LIQUIDATION_REWARD_RATIO) / ONE; // e.g. 2%
        uint256 traderReceive = payout > keeperReward
            ? payout - keeperReward
            : 0;

        // ---------- 3️⃣ Apply to pool + transfers ----------
        _applyPnLToPool(pnl);

        if (keeperReward > 0) usdt.safeTransfer(msg.sender, keeperReward);
        if (traderReceive > 0) usdt.safeTransfer(user, traderReceive);

        // ---------- 4️⃣ Update position ----------
        pos.isClosed = true;
        pos.closePrice = closePrice;
        pos.payout = traderReceive;

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
        if (diff > 0) for (int32 i; i < diff; i++) v *= 10;
        else if (diff < 0) for (int32 i; i < -diff; i++) v /= 10;
        return uint256(v);
    }
}

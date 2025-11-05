// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "lib/pyth-sdk-solidity/PythStructs.sol";
import "lib/pyth-sdk-solidity/IPyth.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract PerpDEX {
    IPyth public immutable pyth;
    ERC20 public immutable usdt;

    // ---------- Ownership ----------
    address public owner;
    modifier onlyOwner() {
        require(msg.sender == owner, "Not admin");
        _;
    }

    // ---------- Fixed-point base ----------
    uint256 public constant ONE = 1e18;

    // ---------- Economic Params ----------
    uint256 public constant FEE_RATIO = 5e14; // 0.05%
    uint256 public constant SPREAD_BPS = 5; // 0.05%
    uint256 public constant MAINTENANCE_MARGIN_RATIO = 10e16; // 10%
    // NOTE: LIQUIDATION_REWARD_RATIO intentionally unused (no keeper reward)
    uint256 public constant MAX_DAILY_FUNDING_BPS = 100; // 1% per day
    uint256 public constant FUNDING_MAX_PER_SEC =
        ((ONE * MAX_DAILY_FUNDING_BPS) / 10000) / 86400;

    // ---------- Data Models ----------
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
        // TP/SL (absolute prices; 0 = unset)
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
    mapping(address => string) public username;

    mapping(string => PairFunding) public pairFunding;
    mapping(string => PairInfo) public pairInfo;
    PairInfo[] public allPairs;
    address[] public allUsers;

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
    event RegisterUser(address indexed userAddress, string username);
    event FundingUpdated(
        string pairs,
        int256 newGrowth,
        uint256 oiLong,
        uint256 oiShort,
        uint256 timestamp
    );
    event PairAdded(string name, bytes32 pythTokenId);
    event PairStatus(string name, bool active);
    event OwnershipTransferred(
        address indexed oldOwner,
        address indexed newOwner
    );
    event AllPositionsClosed(address indexed admin, uint256 timestamp);
    event TpSlSet(
        address indexed user,
        bytes32 indexed positionId,
        uint256 takeProfit,
        uint256 stopLoss
    );
    event TpSlCleared(
        address indexed user,
        bytes32 indexed positionId,
        bool clearedTp,
        bool clearedSl
    );
    event TpSlTriggered(
        address indexed keeper,
        address indexed user,
        bytes32 indexed positionId,
        string triggerType,
        uint256 triggerPrice
    );

    // ✅ Dedicated liquidation event for backend tracking
    event Liquidated(
        address indexed keeper,
        address indexed user,
        bytes32 indexed positionId,
        string pairs,
        uint256 markPrice,
        uint256 timestamp
    );

    // ---------- Constructor ----------
    constructor(address _usdt, address _pyth) {
        require(_usdt != address(0) && _pyth != address(0), "Invalid address");
        usdt = ERC20(_usdt);
        pyth = IPyth(_pyth);
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
        _addInitialPairs();
    }

    // ---------- Initial Pairs ----------
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
        pairInfo[pairs] = PairInfo({
            name: pairs,
            pythTokenId: pythTokenId,
            active: true
        });
        allPairs.push(pairInfo[pairs]);
        emit PairAdded(pairs, pythTokenId);
        emit PairStatus(pairs, true);
    }

    // ---------- Admin Pair Management ----------
    function addPairBatch(
        string[] calldata names,
        bytes32[] calldata pythTokenIds
    ) external onlyOwner {
        require(names.length == pythTokenIds.length, "Length mismatch");
        for (uint256 i = 0; i < names.length; i++) {
            require(!pairInfo[names[i]].active, "Pair exists");
            pairInfo[names[i]] = PairInfo({
                name: names[i],
                pythTokenId: pythTokenIds[i],
                active: true
            });
            allPairs.push(pairInfo[names[i]]);
            emit PairAdded(names[i], pythTokenIds[i]);
            emit PairStatus(names[i], true);
        }
    }

    function addPair(
        string calldata pairs,
        bytes32 pythTokenId
    ) external onlyOwner {
        require(!pairInfo[pairs].active, "Pair exists");
        pairInfo[pairs] = PairInfo({
            name: pairs,
            pythTokenId: pythTokenId,
            active: true
        });
        allPairs.push(pairInfo[pairs]);
        emit PairAdded(pairs, pythTokenId);
        emit PairStatus(pairs, true);
    }

    function setPairActive(
        string calldata pairs,
        bool active
    ) external onlyOwner {
        require(bytes(pairInfo[pairs].name).length > 0, "Pair unknown");
        pairInfo[pairs].active = active;
        emit PairStatus(pairs, active);
    }

    function getAllPairs() external view returns (PairInfo[] memory) {
        return allPairs;
    }

    // ---------- Ownership ----------
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Bad owner");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // ---------- Users ----------
    function registerUser(string calldata _username) external {
        require(bytes(_username).length > 0, "Empty username");
        if (bytes(username[msg.sender]).length == 0) allUsers.push(msg.sender);
        username[msg.sender] = _username;
        emit RegisterUser(msg.sender, _username);
    }

    // ---------- Funding ----------
    function updateFunding(string calldata pairs) public {
        _accrueFunding(pairs);
        PairFunding storage pf = pairFunding[pairs];
        emit FundingUpdated(
            pairs,
            pf.growth,
            pf.oiLong,
            pf.oiShort,
            block.timestamp
        );
    }

    function _accrueFunding(string memory pairs) internal {
        PairFunding storage pf = pairFunding[pairs];
        uint256 last = pf.lastUpdate;
        if (last == 0) {
            pf.lastUpdate = block.timestamp;
            return;
        }

        uint256 dt = block.timestamp - last;
        if (dt == 0) return;

        uint256 longOI = pf.oiLong;
        uint256 shortOI = pf.oiShort;
        uint256 totalOI = longOI + shortOI;
        if (totalOI == 0) {
            pf.lastUpdate = block.timestamp;
            return;
        }

        uint256 diff = longOI > shortOI ? longOI - shortOI : shortOI - longOI;
        uint256 imbalanceRatio = (diff * ONE) / totalOI;
        uint256 magPerSec = (FUNDING_MAX_PER_SEC * imbalanceRatio) / ONE;
        int256 signedPerSec = longOI >= shortOI
            ? int256(magPerSec)
            : -int256(magPerSec);

        pf.growth += signedPerSec * int256(dt);
        pf.lastUpdate = block.timestamp;
    }

    // ---------- Open / Close ----------
    function openPosition(
        string calldata pairs,
        bool isLong,
        uint256 margin,
        uint256 leverage
    ) external {
        require(margin > 0 && leverage > 0, "Bad margin/leverage");
        PairInfo storage info = pairInfo[pairs];
        require(info.active, "Pair not supported");

        require(
            usdt.transferFrom(msg.sender, address(this), margin),
            "USDT pull failed"
        );

        uint256 fees = (margin * leverage * FEE_RATIO) / ONE;
        uint256 netMargin = margin - fees;
        uint256 netSize = netMargin * leverage;

        _finalizeOpenPosition(
            pairs,
            isLong,
            netMargin,
            leverage,
            netSize,
            info.pythTokenId,
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
        _accrueFunding(pairs);

        PythStructs.Price memory token = pyth.getPrice(pythTokenId);
        require(token.price > 0, "Invalid price");

        uint256 oraclePrice = toUint(token.price);
        uint256 entryPrice = applySpread(oraclePrice, isLong, true);
        uint256 liquidationPrice = calculateLiquidationPrice(
            entryPrice,
            netSize,
            netMargin,
            isLong
        );

        bytes32 id = keccak256(
            abi.encodePacked(msg.sender, block.timestamp, block.number)
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
                pythTokenId: pythTokenId,
                isClosed: false,
                closePrice: 0,
                payout: 0,
                liquidationPrice: liquidationPrice,
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
            pythTokenId,
            liquidationPrice,
            fees
        );
    }

    function closePosition(bytes32 positionId) external {
        Position[] storage userPositions = positions[msg.sender];
        for (uint256 i = 0; i < userPositions.length; i++) {
            Position storage pos = userPositions[i];
            if (!pos.isClosed && pos.id == positionId) {
                _closePosition(msg.sender, pos);
                return;
            }
        }
        revert("Position not found/already closed");
    }

    function _closePosition(address user, Position storage pos) internal {
        _accrueFunding(pos.pairs);

        PythStructs.Price memory token = pyth.getPrice(pos.pythTokenId);
        require(token.price > 0, "Invalid price");
        uint256 currentPrice = toUint(token.price);

        int256 pnl = pos.isLong
            ? (int256(pos.size) *
                (int256(currentPrice) - int256(pos.entryPrice))) /
                int256(pos.entryPrice)
            : (int256(pos.size) *
                (int256(pos.entryPrice) - int256(currentPrice))) /
                int256(pos.entryPrice);

        PairFunding storage pf = pairFunding[pos.pairs];
        int256 fundingPayment = (int256(pos.size) *
            (pf.growth - pos.fundingEntry)) / int256(ONE);

        int256 rawPayout = int256(pos.margin) + pnl - fundingPayment;
        uint256 payout = rawPayout > 0 ? uint256(rawPayout) : 0;

        uint256 closeFee = (payout * FEE_RATIO) / ONE;
        payout = payout > closeFee ? payout - closeFee : 0;

        if (pos.isLong)
            pf.oiLong = pf.oiLong >= pos.size ? pf.oiLong - pos.size : 0;
        else pf.oiShort = pf.oiShort >= pos.size ? pf.oiShort - pos.size : 0;

        if (payout > 0) usdt.transfer(user, payout);

        pos.isClosed = true;
        pos.closePrice = currentPrice;
        pos.payout = payout;

        emit ClosePosition(pos.id, user, currentPrice, payout, closeFee);
    }

    // ---------- Liquidation (no keeper reward) ----------
    function liquidatePosition(address user, bytes32 positionId) external {
        Position[] storage userPositions = positions[user];
        for (uint256 i = 0; i < userPositions.length; i++) {
            Position storage pos = userPositions[i];
            if (!pos.isClosed && pos.id == positionId) {
                _accrueFunding(pos.pairs);

                PythStructs.Price memory token = pyth.getPrice(pos.pythTokenId);
                require(token.price > 0, "Invalid price");
                uint256 mark = toUint(token.price);

                bool canLiquidate = pos.isLong
                    ? mark <= pos.liquidationPrice
                    : mark >= pos.liquidationPrice;
                require(canLiquidate, "Not liquidatable");

                PairFunding storage pf = pairFunding[pos.pairs];
                int256 fundingPayment = (int256(pos.size) *
                    (pf.growth - pos.fundingEntry)) / int256(ONE);

                int256 pnl = pos.isLong
                    ? (int256(pos.size) *
                        (int256(mark) - int256(pos.entryPrice))) /
                        int256(pos.entryPrice)
                    : (int256(pos.size) *
                        (int256(pos.entryPrice) - int256(mark))) /
                        int256(pos.entryPrice);

                int256 rawPayout = int256(pos.margin) + pnl - fundingPayment;
                uint256 payout = rawPayout > 0 ? uint256(rawPayout) : 0;

                // No keeper reward; all positive payout returns to the trader
                if (payout > 0) usdt.transfer(user, payout);

                if (pos.isLong)
                    pf.oiLong = pf.oiLong >= pos.size
                        ? pf.oiLong - pos.size
                        : 0;
                else
                    pf.oiShort = pf.oiShort >= pos.size
                        ? pf.oiShort - pos.size
                        : 0;

                pos.isClosed = true;
                pos.closePrice = mark;
                pos.payout = payout;

                // closeFee = 0 for liquidation path
                emit ClosePosition(pos.id, user, mark, payout, 0);
                emit Liquidated(
                    msg.sender,
                    user,
                    positionId,
                    pos.pairs,
                    mark,
                    block.timestamp
                );
                return;
            }
        }
        revert("Position not found/already closed");
    }

    // ---------- Admin Close All ----------
    function closeAllPositions() external onlyOwner {
        for (uint256 u = 0; u < allUsers.length; u++) {
            address user = allUsers[u];
            Position[] storage userPositions = positions[user];
            for (uint256 i = 0; i < userPositions.length; i++) {
                Position storage pos = userPositions[i];
                if (!pos.isClosed) _closePosition(user, pos);
            }
        }
        emit AllPositionsClosed(msg.sender, block.timestamp);
    }

    // ---------- TP/SL ----------
    function setTpSl(
        bytes32 positionId,
        uint256 newTp,
        uint256 newSl
    ) external {
        Position storage pos = _getOpenPositionOf(msg.sender, positionId);

        if (newTp > 0) {
            if (pos.isLong)
                require(newTp > pos.entryPrice, "TP must be > entry");
            else require(newTp < pos.entryPrice, "TP must be < entry");
            pos.takeProfit = newTp;
        }
        if (newSl > 0) {
            if (pos.isLong)
                require(newSl < pos.entryPrice, "SL must be < entry");
            else require(newSl > pos.entryPrice, "SL must be > entry");
            pos.stopLoss = newSl;
        }

        emit TpSlSet(msg.sender, positionId, pos.takeProfit, pos.stopLoss);
    }

    function clearTpSl(
        bytes32 positionId,
        bool clearTp,
        bool clearSl
    ) external {
        Position storage pos = _getOpenPositionOf(msg.sender, positionId);

        bool didTp;
        bool didSl;
        if (clearTp && pos.takeProfit != 0) {
            pos.takeProfit = 0;
            didTp = true;
        }
        if (clearSl && pos.stopLoss != 0) {
            pos.stopLoss = 0;
            didSl = true;
        }
        require(didTp || didSl, "Nothing to clear");

        emit TpSlCleared(msg.sender, positionId, didTp, didSl);
    }

    function triggerTpSl(address user, bytes32 positionId) external {
        Position storage pos = _getOpenPositionOf(user, positionId);

        PythStructs.Price memory token = pyth.getPrice(pos.pythTokenId);
        require(token.price > 0, "Invalid price");
        uint256 mark = toUint(token.price);

        (bool shouldClose, string memory which) = _shouldTrigger(pos, mark);
        require(shouldClose, "No trigger");

        _closePosition(user, pos);
        emit TpSlTriggered(msg.sender, user, positionId, which, mark);
    }

    function _shouldTrigger(
        Position storage pos,
        uint256 mark
    ) internal view returns (bool ok, string memory which) {
        if (pos.isLong) {
            if (pos.takeProfit != 0 && mark >= pos.takeProfit)
                return (true, "TP");
            if (pos.stopLoss != 0 && mark <= pos.stopLoss) return (true, "SL");
        } else {
            if (pos.takeProfit != 0 && mark <= pos.takeProfit)
                return (true, "TP");
            if (pos.stopLoss != 0 && mark >= pos.stopLoss) return (true, "SL");
        }
        return (false, "");
    }

    function _getOpenPositionOf(
        address user,
        bytes32 positionId
    ) internal view returns (Position storage) {
        Position[] storage arr = positions[user];
        for (uint256 i = 0; i < arr.length; i++) {
            if (!arr[i].isClosed && arr[i].id == positionId) {
                return arr[i];
            }
        }
        revert("Position not found/already closed");
    }

    // ---------- Helpers ----------
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

    function applySpread(
        uint256 price,
        bool isLong,
        bool isEntry
    ) internal pure returns (uint256) {
        uint256 spread = (price * SPREAD_BPS) / 10000;
        if (isEntry) return isLong ? price + spread : price - spread;
        return isLong ? price - spread : price + spread;
    }

    function toUint(int64 x) internal pure returns (uint256) {
        require(x >= 0, "Negative price");
        return uint256(uint64(x));
    }
}

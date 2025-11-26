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
    uint256 public constant LIQUIDATION_REWARD_RATIO = 2e16; // 2%

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

    // ---------- Constructor ----------
    constructor(address _usdt, address _pyth) {
        require(_usdt != address(0) && _pyth != address(0), "Invalid address");
        usdt = ERC20(_usdt);
        pyth = IPyth(_pyth);
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
        _addInitialPairs();
    }

    // ---------- Receive Native Token ----------
    receive() external payable {}

    // ---------- Initial Pairs ----------
    function _addInitialPairs() internal {
        // --- Tier 1 ---
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
            "BNB_USD",
            0x9446c2c3a3e4bd5e860f87d50986e2a38c2a99ce2c8bf0e27eaeedc038c45f5a
        );

        // --- Tier 2 ---
        addPairInternal(
            "XRP_USD",
            0x2c479522b2f7f46873c551d20b93257f8a555ba3b3f85c2e6aa1f3fa48a125a6
        );
        addPairInternal(
            "DOGE_USD",
            0xe3740a8d5ac52df6c7fb1d9902e3f0f677cbcbbce8f9250ab297927651c01c75
        );
        addPairInternal(
            "ADA_USD",
            0x7abcfabf0d29e0c746ae8269664532c9b6e587f8515cdaf8cd0d063fe12fb6e9
        );
        addPairInternal(
            "AVAX_USD",
            0x99c9fcad6a22039f8a30dd6cf157d6762f9598a0b851a2eca40d767bc9f6b6e9
        );
        addPairInternal(
            "DOT_USD",
            0x06ce9f3722a8ee1bc74d2c4aa1bea1269234ab813a2dd8f04fbf0e466c0aa78e
        );
        addPairInternal(
            "LINK_USD",
            0x7cff55df4cd61b52dbb39d315b8e322ad9b2dd2acda6cd65a14e3b0d615b5fba
        );

        // --- Tier 3 ---
        addPairInternal(
            "MATIC_USD",
            0xa2b2f4a868478bfae4c2a8e1d5c9961c3c2de1428c4933cfd5e7ed661dc57a41
        );
        addPairInternal(
            "ARB_USD",
            0x4c2a4f8b2ddb3f7e61a821a3d1d40d7b9050bc0f25bf3cce61a86342f3b15413
        );
        addPairInternal(
            "OP_USD",
            0x174a4c2a8e085e8f2fa2a343b3bf3cdea621ada5cef66216c0daac824bd8b020
        );
        addPairInternal(
            "ATOM_USD",
            0x26dbd2f19e0a9d5b5947f2a7bc01db57ee0ebf1d4c25a11f703e270d417c9e27
        );
        addPairInternal(
            "NEAR_USD",
            0xa3b522d07f0e5a53ce38adcb7631c6fba58898d2c0f473a223e7b2b1136f4e18
        );

        // --- Tier 4 ---
        addPairInternal(
            "APT_USD",
            0x8d5508d64c9f32d438c523c4c7183762c508d57f075444ef32272acab56543fa
        );
        addPairInternal(
            "SUI_USD",
            0x63b4e5b2de6301d3ba93926ab9dd98ec6053b457769278ade41b1a086e404f38
        );
        addPairInternal(
            "TON_USD",
            0x94f5a7d6a2f1f6ec0e1f8e8542343d0853788c5f6d3cbb3f315b2e878f8e3b44
        );
        addPairInternal(
            "TRX_USD",
            0x7092344747f29a8b2b5fcb1b61bf3eefec9e3ea364ab53976673f2dc16fc7d72
        );
        addPairInternal(
            "SHIB_USD",
            0x14addd41f6bb9915eddbb144a4bb6b0de2ac821f2d3b9fa9026fb7c6b1d10abf
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
                fundingEntry: pf.growth
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

    // ✅ Modified Close (no spread + fee on close)
    function _closePosition(address user, Position storage pos) internal {
        _accrueFunding(pos.pairs);

        PythStructs.Price memory token = pyth.getPrice(pos.pythTokenId);
        require(token.price > 0, "Invalid price");
        uint256 currentPrice = toUint(token.price); // ✅ No spread

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

        // ✅ Apply close fee (same as FEE_RATIO)
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
        return uint256(int256(x));
    }
}

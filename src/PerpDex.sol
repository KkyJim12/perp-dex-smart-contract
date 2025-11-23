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

    // ---------- Staking Pool (LP Shares) ----------
    // totalStaked = total pool value (accounting for PnL)
    uint256 public totalStaked;
    uint256 public totalShares;
    mapping(address => uint256) public shares;

    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event PoolUpdated(uint256 totalStaked, string reason, int256 pnlImpact);

    // Helper: current value of a user's stake
    function stakeValueOf(address user) external view returns (uint256) {
        if (totalShares == 0) return 0;
        return (shares[user] * totalStaked) / totalShares;
    }

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
        addPairInternal(
            "BNB_USD",
            0x1b63cd6b637e4f9ee97c445ecf74db4dbda023ddc969444fdb3ac0b2db6f4f38
        );
        addPairInternal(
            "XRP_USD",
            0x48c132276ddec5e199a706456f4c662e4fab6c8c1e7d7903b806cd0310a2f3fd
        );
        addPairInternal(
            "DOGE_USD",
            0x28f6c39eaca5f05d39b1c3c2de1428c4933c6d53295d85f1e4b74e6a12d37d90
        );
        addPairInternal(
            "ADA_USD",
            0x1fca736f6f75dd8c2c508d57f075444ef98a32956543d4d6acdfd1cb1f3f325c
        );
        addPairInternal(
            "AVAX_USD",
            0x1d4b6836c73e84c291a8521fbca2d3b5a793bcee66475d27be27fa9982d75c51
        );
        addPairInternal(
            "DOT_USD",
            0x38fc8b4f1bb1c56b99a15c1e71e83cd8b67f52c16e491061b85d34ed2a5b3735
        );
        addPairInternal(
            "LINK_USD",
            0x21bea2cd2915a3798648a86d51db7c7a98e103ef393d5dc408dc325a71cbb320
        );
        addPairInternal(
            "MATIC_USD",
            0xe96a3f4b8ce9f5a353a811d873d57ddc00c45ea1ab696648efa6247aa92c03af
        );
        addPairInternal(
            "ARB_USD",
            0x4fb6ec3c84f8d1f8dbd10be50e7d652e0f1f5e9a98525d2c58e7766505f5f99c
        );
        addPairInternal(
            "OP_USD",
            0x947228f522c3e1f54a73b17e5cfea9800a2c82fbc5e6a5e672ff7e94ece66d3c
        );
        addPairInternal(
            "ATOM_USD",
            0xb5feea9c36e4b7eb237c54b4cfabd0c4f2b1f4ba1a4e4e5ea22dd8f2fa16a9c9
        );
        addPairInternal(
            "NEAR_USD",
            0x1af3d9df238dab28c166a4630bf8c1c58ddc3e39fb8bcbac2b33cd807401e33b
        );
        addPairInternal(
            "APT_USD",
            0xd3eac9f33e049d072a61668b22afcf576c69e6f1a02ce3066f7f505f98ed0a88
        );
        addPairInternal(
            "SUI_USD",
            0x5646660deab97842423061faf03a6f6883bc5a81c853719fd5e4f2addbf1f3c6
        );
    }

    function addPairInternal(
        string memory pairs,
        bytes32 pythTokenId
    ) internal {
        pairInfo[pairs] = PairInfo(pairs, pythTokenId, true);
        allPairs.push(pairInfo[pairs]);
    }

    // ---------- Staking (LP Shares) ----------
    /**
     * @notice Stake USDT into the pool and receive LP shares.
     * LP share price = totalStaked / totalShares
     */
    function stake(uint256 amount) external nonReentrant {
        require(amount > 0, "Zero amount");
        usdt.safeTransferFrom(msg.sender, address(this), amount);

        uint256 mintShares;
        if (totalStaked == 0 || totalShares == 0) {
            // First liquidity provider or reset: 1:1 mapping
            mintShares = amount;
        } else {
            // Maintain proportional ownership
            mintShares = (amount * totalShares) / totalStaked;
        }

        require(mintShares > 0, "Zero shares");

        totalStaked += amount;
        shares[msg.sender] += mintShares;
        totalShares += mintShares;

        emit Staked(msg.sender, amount);
    }

    /**
     * @notice Unstake by burning LP shares and receive pro-rata USDT.
     * @param shareAmount Amount of LP shares to burn.
     */
    function unstake(uint256 shareAmount) external nonReentrant {
        require(shareAmount > 0, "Zero shares");
        require(shares[msg.sender] >= shareAmount, "Not enough shares");
        require(totalShares > 0, "No shares");

        uint256 amountOut = (shareAmount * totalStaked) / totalShares;

        shares[msg.sender] -= shareAmount;
        totalShares -= shareAmount;
        totalStaked -= amountOut;

        usdt.safeTransfer(msg.sender, amountOut);

        emit Unstaked(msg.sender, amountOut);
    }

    // ---------- Core: Pool PnL ----------
    /**
     * @dev Positive pnl => trader win => pool loses.
     *      Negative pnl => trader loss => pool gains.
     *      This directly changes LP share price.
     */
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

        uint256 closePrice = mark; // no spread on close
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

    // ---------- TP/SL Management ----------
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
        uint256 closePrice = triggerPrice;
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

    // ---------- Liquidation ----------
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
        if (diff > 0) {
            for (int32 i; i < diff; i++) v *= 10;
        } else if (diff < 0) {
            for (int32 i; i < -diff; i++) v /= 10;
        }
        return uint256(v);
    }
}

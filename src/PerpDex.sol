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
    uint256 public constant FEE_RATIO = 0; // 0% open/close fee (for now)
    uint256 public constant SPREAD_BPS = 0; // 0 bps spread (for now)
    uint256 public constant MAINTENANCE_MARGIN_RATIO = 0; // 0% =>  
    uint256 public constant LIQUIDATION_REWARD_RATIO = 2e16; // 2% (currently unused)

    uint256 public constant MAX_DAILY_FUNDING_BPS = 100; // 1% per day max
    uint256 public constant FUNDING_MAX_PER_SEC =
        ((ONE * MAX_DAILY_FUNDING_BPS) / 10000) / 86400;

    // 🔥 Max PnL = 500% of margin (so profit <= 5x margin)
    uint256 public constant MAX_PNL_RATIO = 5e18; // 500% expressed in 1e18 fixed-point

    // ---------- Data Models ----------
    struct Position {
        bytes32 id;
        string pairs;
        bool isLong;
        uint256 margin; // netMargin (after open fee)
        uint256 leverage;
        uint256 size; // position notional
        uint256 entryPrice;
        bytes32 pythTokenId;
        bool isClosed;
        uint256 closePrice;
        uint256 payout;
        uint256 liquidationPrice;
        uint256 fees; // open fee
        int256 fundingEntry;
        uint256 takeProfit; // 0 = none
        uint256 stopLoss; // 0 = none
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

    // ---------- LP Pool ----------
    uint256 public totalLpShares;
    mapping(address => uint256) public lpShares;

    // Sum of margin locked in open positions (netMargin only)
    uint256 public totalOpenMargin;

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

    // LP events
    event LPDeposit(address indexed user, uint256 amount, uint256 shares);
    event LPWithdraw(address indexed user, uint256 amount, uint256 shares);

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
            0x2f95862b045670cd22bee3114c39763a4a08beeb663b145d283c31d7d1101c4f
        );
        addPairInternal(
            "XRP_USD",
            0xec5d399846a9209f3fe5881d70aae9268c94339ff9817e8d18ff19fa05eea1c8
        );
        addPairInternal(
            "DOGE_USD",
            0xdcef50dd0a4cd2dcc17e45df1676dcb336a11a61c69df7a0299b0150c672d25c
        );
        addPairInternal(
            "HYPE_USD",
            0x4279e31cc369bbcc2faf022b382b080e32a8e689ff20fbc530d2a603eb6cd98b
        );
        addPairInternal(
            "SUI_USD",
            0x23d7315113f5b1d3ba7a83604c44b94d79f4fd69af77f804fc7f920a6dc65744
        );
        addPairInternal(
            "OP_USD",
            0x385f64d993f7b77d8182ed5003d97c60aa3361f3cecfe711544d2d59165e9bdf
        );
        addPairInternal(
            "ARB_USD",
            0x3fa4252848f9f0a1480be62745a4629d9eb1322aebab8a791e344b3b9c1adcf5
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
        if (bytes(username[msg.sender]).length == 0) {
            allUsers.push(msg.sender);
        }
        username[msg.sender] = _username;
        emit RegisterUser(msg.sender, _username);
    }

    function editUsername(string calldata _username) external {
        require(bytes(_username).length > 0, "Empty username");
        require(bytes(username[msg.sender]).length > 0, "Not registered");
        username[msg.sender] = _username;
        emit RegisterUser(msg.sender, _username);
    }

    // ===============================================================
    // LP POOL LOGIC
    // ===============================================================

    /// @dev LP equity = USDT balance - totalOpenMargin
    function getPoolValue() public view returns (uint256) {
        uint256 bal = usdt.balanceOf(address(this));
        if (bal > totalOpenMargin) {
            return bal - totalOpenMargin;
        }
        return 0;
    }

    function getSharePrice() external view returns (uint256) {
        if (totalLpShares == 0) return ONE;
        uint256 pool = getPoolValue();
        return (pool * ONE) / totalLpShares;
    }

    /// @notice Deposit USDT to the LP pool and receive LP shares
    function depositLP(uint256 amount) external {
        require(amount > 0, "amount=0");

        uint256 poolBefore = getPoolValue();
        uint256 shares;

        if (totalLpShares == 0 || poolBefore == 0) {
            // initial: 1:1
            shares = amount;
        } else {
            shares = (amount * totalLpShares) / poolBefore;
        }

        require(shares > 0, "shares=0");

        require(
            usdt.transferFrom(msg.sender, address(this), amount),
            "USDT transfer failed"
        );

        lpShares[msg.sender] += shares;
        totalLpShares += shares;

        emit LPDeposit(msg.sender, amount, shares);
    }

    /// @notice Withdraw USDT by burning LP shares
    function withdrawLP(uint256 shares) external {
        require(shares > 0, "shares=0");
        uint256 userShares = lpShares[msg.sender];
        require(userShares >= shares, "insufficient shares");

        uint256 pool = getPoolValue();
        require(pool > 0 && totalLpShares > 0, "empty pool");

        uint256 amount = (shares * pool) / totalLpShares;
        require(amount > 0, "amount=0");

        lpShares[msg.sender] = userShares - shares;
        totalLpShares -= shares;

        require(usdt.transfer(msg.sender, amount), "USDT transfer failed");
        emit LPWithdraw(msg.sender, amount, shares);
    }

    // ===============================================================
    // FUNDING
    // ===============================================================

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

    // ===============================================================
    // PYTH HELPERS (PULL ORACLE)
    // ===============================================================

    /// @dev Updates Pyth price feeds with fresh updateData (Hermes)
    ///      and returns the current Price struct for the given priceId.
    function _updateAndGetPythPrice(
        bytes[] calldata priceUpdateData,
        bytes32 priceId
    ) internal returns (PythStructs.Price memory) {
        uint256 fee = pyth.getUpdateFee(priceUpdateData);
        require(msg.value >= fee, "Insufficient Pyth fee");
        pyth.updatePriceFeeds{value: fee}(priceUpdateData);

        // Now get the (fresh) price
        PythStructs.Price memory p = pyth.getPrice(priceId);
        require(p.price > 0, "Invalid Pyth price");
        return p;
    }

    // ===============================================================
    // OPEN POSITION (uses Pyth pull oracle)
    // ===============================================================

    function openPosition(
        string calldata pairs,
        bool isLong,
        uint256 margin,
        uint256 leverage,
        bytes[] calldata priceUpdateData,
        uint256 takeProfit, // 0 = none
        uint256 stopLoss // 0 = none
    ) external payable {
        require(margin > 0 && leverage > 0, "Bad margin/leverage");

        PairInfo storage info = pairInfo[pairs];
        require(info.active, "Pair not supported");

        // 1) Update Pyth and get fresh price for this pair
        PythStructs.Price memory token = _updateAndGetPythPrice(
            priceUpdateData,
            info.pythTokenId
        );
        uint256 oraclePrice = toUint(token.price);

        // 2) Pull margin from trader
        require(
            usdt.transferFrom(msg.sender, address(this), margin),
            "USDT pull failed"
        );

        // 3) Fee + net margin
        uint256 fees = (margin * leverage * FEE_RATIO) / ONE;
        uint256 netMargin = margin - fees;
        uint256 netSize = netMargin * leverage;

        // 4) Track locked margin for pool-equity calculations
        totalOpenMargin += netMargin;

        _finalizeOpenPosition(
            pairs,
            isLong,
            netMargin,
            leverage,
            netSize,
            info.pythTokenId,
            fees,
            oraclePrice,
            takeProfit,
            stopLoss
        );
    }

    function _finalizeOpenPosition(
        string calldata pairs,
        bool isLong,
        uint256 netMargin,
        uint256 leverage,
        uint256 netSize,
        bytes32 pythTokenId,
        uint256 fees,
        uint256 signedPrice,
        uint256 tp,
        uint256 sl
    ) internal {
        _accrueFunding(pairs);

        uint256 entryPrice = applySpread(signedPrice, isLong, true);

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
                takeProfit: tp,
                stopLoss: sl
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

    // ===============================================================
    // MODIFY TP / SL
    // ===============================================================

    function modifyTpSl(
        bytes32 positionId,
        uint256 newTP,
        uint256 newSL
    ) external {
        Position[] storage userPositions = positions[msg.sender];

        for (uint256 i = 0; i < userPositions.length; i++) {
            Position storage pos = userPositions[i];

            if (pos.id == positionId && !pos.isClosed) {
                if (newTP > 0) {
                    pos.takeProfit = newTP;
                } else {
                    pos.takeProfit = 0;
                }

                if (newSL > 0) {
                    pos.stopLoss = newSL;
                } else {
                    pos.stopLoss = 0;
                }

                return;
            }
        }

        revert("Position not found");
    }

    // ===============================================================
    // CLOSE POSITION (manual close using fresh Pyth price)
    // ===============================================================

    function closePosition(
        bytes32 positionId,
        bytes[] calldata priceUpdateData
    ) external payable {
        Position[] storage userPositions = positions[msg.sender];
        for (uint256 i = 0; i < userPositions.length; i++) {
            Position storage pos = userPositions[i];
            if (!pos.isClosed && pos.id == positionId) {
                // Fetch fresh price from Pyth for manual close
                PythStructs.Price memory token = _updateAndGetPythPrice(
                    priceUpdateData,
                    pos.pythTokenId
                );
                uint256 currentPrice = toUint(token.price); // no spread on close

                _closePosition(msg.sender, pos, currentPrice);
                return;
            }
        }
        revert("Position not found/already closed");
    }

    // ===============================================================
    // TP/SL TRIGGER (bot) - close at Pyth TP/SL price
    // ===============================================================

    function triggerTpSl(
        address user,
        bytes32 positionId,
        bytes[] calldata priceUpdateData
    ) external payable {
        Position[] storage userPositions = positions[user];

        for (uint256 i = 0; i < userPositions.length; i++) {
            Position storage pos = userPositions[i];

            if (pos.id == positionId && !pos.isClosed) {
                // Fresh Pyth price
                PythStructs.Price memory token = _updateAndGetPythPrice(
                    priceUpdateData,
                    pos.pythTokenId
                );
                uint256 oraclePrice = toUint(token.price);

                bool hitTP = false;
                bool hitSL = false;

                // Long: TP if price >= TP, SL if price <= SL
                // Short: TP if price <= TP, SL if price >= SL
                if (pos.takeProfit > 0) {
                    if (pos.isLong && oraclePrice >= pos.takeProfit)
                        hitTP = true;
                    if (!pos.isLong && oraclePrice <= pos.takeProfit)
                        hitTP = true;
                }

                if (pos.stopLoss > 0) {
                    if (pos.isLong && oraclePrice <= pos.stopLoss) hitSL = true;
                    if (!pos.isLong && oraclePrice >= pos.stopLoss)
                        hitSL = true;
                }

                require(hitTP || hitSL, "No TP/SL triggered");

                // Close using oraclePrice (exact TP/SL execution)
                _closePosition(user, pos, oraclePrice);

                return;
            }
        }

        revert("Position not found");
    }

    // ===============================================================
    // LIQUIDATION (bot)
    // ===============================================================

    function liquidate(
        address user,
        bytes32 positionId,
        bytes[] calldata priceUpdateData
    ) external payable {
        Position[] storage userPositions = positions[user];

        for (uint256 i = 0; i < userPositions.length; i++) {
            Position storage pos = userPositions[i];

            if (pos.id == positionId && !pos.isClosed) {
                // --- 1) Get fresh price from Pyth ---
                PythStructs.Price memory token = _updateAndGetPythPrice(
                    priceUpdateData,
                    pos.pythTokenId
                );
                uint256 oraclePrice = toUint(token.price);

                // --- 2) Compute PnL ---
                int256 pnl = pos.isLong
                    ? (int256(pos.size) *
                        (int256(oraclePrice) - int256(pos.entryPrice))) /
                        int256(pos.entryPrice)
                    : (int256(pos.size) *
                        (int256(pos.entryPrice) - int256(oraclePrice))) /
                        int256(pos.entryPrice);

                PairFunding storage pf = pairFunding[pos.pairs];
                int256 fundingPayment = (int256(pos.size) *
                    (pf.growth - pos.fundingEntry)) / int256(ONE);

                int256 equity = int256(pos.margin) + pnl - fundingPayment;

                // --- 3) Check liquidation condition ---
                // MAINTENANCE_MARGIN = 0 → equity must be <= 0
                require(equity <= 0, "Position not liquidatable");

                // --- 4) Reduce OI ---
                if (pos.isLong) {
                    pf.oiLong = pf.oiLong >= pos.size
                        ? pf.oiLong - pos.size
                        : 0;
                } else {
                    pf.oiShort = pf.oiShort >= pos.size
                        ? pf.oiShort - pos.size
                        : 0;
                }

                // --- 5) Deduct locked margin ---
                if (totalOpenMargin >= pos.margin) {
                    totalOpenMargin -= pos.margin;
                } else {
                    totalOpenMargin = 0;
                }

                // --- 6) Liquidator reward (optional, currently disabled) ---
                // uint256 reward = (pos.margin * LIQUIDATION_REWARD_RATIO) / ONE;
                // if (reward > 0) usdt.transfer(msg.sender, reward);

                // --- 7) No payout to trader, they lost margin ---
                pos.isClosed = true;
                pos.closePrice = oraclePrice;
                pos.payout = 0;

                emit ClosePosition(
                    pos.id,
                    user,
                    oraclePrice,
                    0,
                    0 // no fee
                );

                return;
            }
        }

        revert("Position not found");
    }

    // ===============================================================
    // Internal close logic (shared by manual close & TP/SL trigger)
    // ===============================================================

    function _closePosition(
        address user,
        Position storage pos,
        uint256 currentPrice
    ) internal {
        _accrueFunding(pos.pairs);

        // Basic PnL formula
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

        // 🔥 Cap PnL at +500% of margin
        int256 cappedPnl = pnl;
        if (cappedPnl > 0) {
            int256 maxPnl = int256((pos.margin * MAX_PNL_RATIO) / ONE); // 5x margin
            if (cappedPnl > maxPnl) {
                cappedPnl = maxPnl;
            }
        }

        int256 rawPayout = int256(pos.margin) + cappedPnl - fundingPayment;
        uint256 payout = rawPayout > 0 ? uint256(rawPayout) : 0;

        // Close fee to pool (currently 0)
        uint256 closeFee = (payout * FEE_RATIO) / ONE;
        payout = payout > closeFee ? payout - closeFee : 0;

        // Update OI
        if (pos.isLong) {
            pf.oiLong = pf.oiLong >= pos.size ? pf.oiLong - pos.size : 0;
        } else {
            pf.oiShort = pf.oiShort >= pos.size ? pf.oiShort - pos.size : 0;
        }

        // Release locked margin tracking
        if (totalOpenMargin >= pos.margin) {
            totalOpenMargin -= pos.margin;
        } else {
            totalOpenMargin = 0;
        }

        // Payout to trader comes from pool
        if (payout > 0) {
            require(usdt.transfer(user, payout), "USDT transfer failed");
        }

        pos.isClosed = true;
        pos.closePrice = currentPrice;
        pos.payout = payout;

        emit ClosePosition(pos.id, user, currentPrice, payout, closeFee);
    }

    // ===============================================================
    // Admin: Close all positions (emergency, uses whatever on-chain Pyth price)
    // ===============================================================

    function closeAllPositions() external onlyOwner {
        for (uint256 u = 0; u < allUsers.length; u++) {
            address user = allUsers[u];
            Position[] storage userPositions = positions[user];
            for (uint256 i = 0; i < userPositions.length; i++) {
                Position storage pos = userPositions[i];
                if (!pos.isClosed) {
                    PythStructs.Price memory token = pyth.getPrice(
                        pos.pythTokenId
                    );
                    if (token.price <= 0) {
                        continue;
                    }
                    uint256 currentPrice = toUint(token.price);
                    _closePosition(user, pos, currentPrice);
                }
            }
        }
        emit AllPositionsClosed(msg.sender, block.timestamp);
    }

    // ===============================================================
    // Helpers
    // ===============================================================

    function calculateLiquidationPrice(
        uint256 entryPrice,
        uint256 size,
        uint256 margin,
        bool isLong
    ) internal pure returns (uint256) {
        // With MAINTENANCE_MARGIN_RATIO = 0, this becomes bankruptcy price:
        // priceChange = entryPrice * margin / size = entryPrice / leverage
        uint256 maint = (margin * MAINTENANCE_MARGIN_RATIO) / ONE; // = 0 now
        uint256 effective = margin - maint;
        uint256 priceChange = (entryPrice * effective) / size;

        return isLong ? entryPrice - priceChange : entryPrice + priceChange;
    }

    function applySpread(
        uint256 price,
        bool isLong,
        bool isEntry
    ) internal pure returns (uint256) {
        uint256 spread = (price * SPREAD_BPS) / 10000;
        if (isEntry) {
            return isLong ? price + spread : price - spread;
        }
        return isLong ? price - spread : price + spread;
    }

    function toUint(int64 x) internal pure returns (uint256) {
        require(x >= 0, "Negative price");
        return uint256(int256(x));
    }
}

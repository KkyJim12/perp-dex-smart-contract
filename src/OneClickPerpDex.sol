// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

interface IocUSDC {
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
}

/**
 * @title OneClickPerpDex
 * @dev Backend-managed perpetual trading with internal balance system and separate LP vault
 * - Users deposit USDC first into their internal balance
 * - Backend handles position management (open/close/TP/SL) using user's deposited funds
 * - Users can withdraw their available balance (not locked in positions) anytime
 * - Has its own LP vault (separate from main PerpDex)
 * - Uses separate ocUSDC token for this vault
 */
contract OneClickPerpDex is ReentrancyGuard {
    error InvalidLeverage();
    error PositionSizeTooLarge();
    error InsufficientAvailableBalance();

    ERC20 public usdc;
    IocUSDC public ocUSDC; // LP token for this vault (OneClickPerpDex Pool USDC)
    address public owner;

    uint256 public constant ONE = 1e18;
    uint256 public constant PLATFORM_FEE_BPS = 150; // 1.5% of realized profit
    uint256 public constant LP_FEE_BPS = 200; // 2% of realized profit
    uint256 public constant WINNING_FEE_BPS = PLATFORM_FEE_BPS + LP_FEE_BPS; // 3.5% total
    uint256 public constant SPREAD_BPS = 0;
    uint256 public constant MIN_MARGIN = 1e6; // 1 USDC
    // Profit ratios use 18 decimals: 1e18 = 100% profit on position margin.
    uint256 public constant DEFAULT_MAX_TP = 5e18; // 500%
    uint256 public constant MAX_PNL_RATIO = DEFAULT_MAX_TP; // Backwards-compatible alias

    struct Position {
        bytes32 id;
        string pairs;
        bool isLong;
        uint256 margin;
        uint256 leverage;
        uint256 size;
        uint256 entryPrice;
        bool isClosed;
        uint256 closePrice;
        uint256 payout;
        uint256 liquidationPrice;
        uint256 fees;
        uint256 takeProfit;
        uint256 stopLoss;
    }

    struct PairInfo {
        string name;
        bool active;
        uint256 liquidityRatio; // Relative weight of LP capital allocated to this pair
        uint256 maxPositionSize; // Max size per position in USDC (e.g., 5000e6 = 5000 USDC)
        uint256 currentLongOI; // Open long notional: sum of margin * leverage
        uint256 currentShortOI; // Open short notional: sum of margin * leverage
        uint256 minLeverage; // Minimum leverage allowed (e.g., 2 = 2x)
        uint256 maxLeverage; // Maximum leverage allowed (e.g., 100 = 100x)
        uint256 maxTP; // Maximum gross profit as a ratio of margin (1e18 = 100%)
        uint256 availableLiquidity; // Remaining margin capacity, calculated by the pair getters
        uint256 usedLiquidity; // Total open long + short margin in collateral units
    }

    struct OpenMargins {
        uint256 longMargin;
        uint256 shortMargin;
    }

    mapping(string => OpenMargins) private pairOpenMargins;
    mapping(address => Position[]) public positions;
    mapping(address => string) public username;
    mapping(string => address) public usernameTaken;
    mapping(string => PairInfo) private _pairInfo;
    mapping(string => bool) public pairPaused;

    string[] private pairNames;
    address[] public allUsers;

    uint256 public totalOpenMargin;
    uint256 public totalLiquidityRatio; // Sum of all pair liquidity allocation weights

    // Maximum aggregate trader profit if every open position reaches its
    // original pair maxTP. This is the amount of LP capital reserved for profit.
    uint256 public totalWorstCaseProfit;
    mapping(bytes32 => uint256) public positionWorstCaseProfit;

    uint256 public constant MAX_DRAWDOWN_BPS = 3_000; // 30%
    uint256 public constant BPS = 10_000;
    bool public tradingPaused;
    uint256 public latestLiquiditySnapshot;
    uint256 public lastLiquiditySnapshotTimestamp;

    // User fund management (internal balance)
    mapping(address => uint256) public userBalances;
    mapping(address => uint256) public lockedBalances;
    // Aggregate all trader balances. Unlike `allUsers`, this also covers users
    // who deposit without registering a username.
    uint256 public totalUserBalances;

    // USDC explicitly committed to the OneClick LP pool. This is kept
    // separate from the contract's USDC balance, which also holds trader
    // deposits and secondary-vault funds.
    uint256 public totalStakedUSDC;

    // Vault PnL Tracking
    int256 public vaultTotalPnL;
    uint256 public vaultTotalProfit;
    uint256 public vaultTotalLoss;

    // Secondary Vault (Fee Vault)
    uint256 public totalSecondaryShares;
    mapping(address => uint256) public secondaryShares;
    uint256 public secondaryVaultBalance;

    // Backend authorization
    mapping(address => bool) public authorizedBackends;

    event OpenPosition(
        bytes32 indexed id,
        address indexed user,
        string pairs,
        bool isLong,
        uint256 margin,
        uint256 leverage,
        uint256 size,
        uint256 entryPrice,
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
        uint256 closeFee,
        string status
    );

    event Deposit(address indexed user, uint256 amount, uint256 newBalance);
    event Withdraw(address indexed user, uint256 amount, uint256 newBalance);
    event RegisterUser(address indexed userAddress, string username);
    event PairAdded(string name);
    event PairStatus(string name, bool active);
    event PairPaused(string name, bool paused);
    event AllPositionsClosed(address indexed admin, uint256 timestamp);
    event TPSLModified(bytes32 indexed positionId, address indexed user, uint256 newTakeProfit, uint256 newStopLoss);
    event FeeCollected(bytes32 indexed positionId, address indexed user, uint256 feeAmount);
    event ProfitFeeSplit(bytes32 indexed positionId, uint256 platformFee, uint256 liquidityFee);
    event LPDeposit(address indexed user, uint256 amount, uint256 shares);
    event LPWithdraw(address indexed user, uint256 amount, uint256 shares);
    event SecondaryVaultDeposit(address indexed user, uint256 amount, uint256 shares);
    event SecondaryVaultWithdraw(address indexed user, uint256 amount, uint256 shares);
    event VaultBackupUsed(uint256 amount, uint256 timestamp);
    event BackendAuthorized(address indexed backend, bool authorized);
    event LiquiditySnapshot(uint256 poolValue, uint256 timestamp);
    event TradingPaused(uint256 poolValue, uint256 drawdownThreshold);
    event TradingResumed(address indexed admin);

    modifier onlyAuthorizedBackend() {
        require(authorizedBackends[msg.sender], "Not authorized backend");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier whenTradingActive() {
        require(!tradingPaused, "Trading paused");
        _;
    }

    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    constructor(address _usdc, address _ocUSDC) {
        _initialize(_usdc, _ocUSDC, msg.sender);
    }

    function _initialize(
        address _usdc,
        address _ocUSDC,
        address initialOwner
    ) internal {
        require(_usdc != address(0) && _ocUSDC != address(0), "Invalid address");
        require(initialOwner != address(0), "Invalid owner");
        usdc = ERC20(_usdc);
        ocUSDC = IocUSDC(_ocUSDC);
        owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid owner");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    receive() external payable {}

    function _addPair(
        string memory pairs,
        uint256 liquidityRatio,
        uint256 maxPositionSize,
        uint256 minLeverage,
        uint256 maxLeverage,
        uint256 maxTP
    ) internal {
        _validatePairMaxTP(maxTP);
        _pairInfo[pairs] = PairInfo(
            pairs,
            true,
            liquidityRatio,
            maxPositionSize,
            0,
            0,
            minLeverage,
            maxLeverage,
            maxTP,
            0,
            0
        );
        pairNames.push(pairs);
        totalLiquidityRatio += liquidityRatio; // Add to total ratio sum
        emit PairAdded(pairs);
        emit PairStatus(pairs, true);
    }

    // ------------------------------------------------------------------
    // BACKEND MANAGEMENT
    // ------------------------------------------------------------------

    function authorizeBackend(address backend, bool authorized) external onlyOwner {
        authorizedBackends[backend] = authorized;
        emit BackendAuthorized(backend, authorized);
    }

    // ------------------------------------------------------------------
    // USER FUND MANAGEMENT (Deposit/Withdraw)
    // ------------------------------------------------------------------

    function deposit(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be > 0");
        
        require(usdc.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        
        userBalances[msg.sender] += amount;
        totalUserBalances += amount;
        
        emit Deposit(msg.sender, amount, userBalances[msg.sender]);
    }

    function withdraw(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be > 0");
        
        uint256 availableBalance = getAvailableBalance(msg.sender);
        require(availableBalance >= amount, "Insufficient available balance");
        
        userBalances[msg.sender] -= amount;
        totalUserBalances -= amount;
        
        require(usdc.transfer(msg.sender, amount), "Transfer failed");
        
        emit Withdraw(msg.sender, amount, userBalances[msg.sender]);
    }

    function getAvailableBalance(address user) public view returns (uint256) {
        uint256 totalBalance = userBalances[user];
        uint256 locked = lockedBalances[user];
        return totalBalance > locked ? totalBalance - locked : 0;
    }

    // ------------------------------------------------------------------
    // Register Username
    // ------------------------------------------------------------------
    
    function registerUsername(string calldata newName) external {
        require(bytes(newName).length > 0, "Empty username");
        require(usernameTaken[newName] == address(0), "Name already used");

        string memory oldName = username[msg.sender];

        if (bytes(oldName).length > 0) {
            usernameTaken[oldName] = address(0);
        } else {
            allUsers.push(msg.sender);
        }

        username[msg.sender] = newName;
        usernameTaken[newName] = msg.sender;

        emit RegisterUser(msg.sender, newName);
    }

    // ------------------------------------------------------------------
    // LP VAULT (Separate from main PerpDex)
    // ------------------------------------------------------------------

    function getPoolValue() public view returns (uint256) {
        // Neither trader funds nor the platform/secondary vault belongs to LPs.
        uint256 contractBalance = usdc.balanceOf(address(this));
        uint256 reserved = totalUserBalances + secondaryVaultBalance;
        return contractBalance > reserved ? contractBalance - reserved : 0;
    }

    function getTotalUserFunds() public view returns (uint256) {
        return totalUserBalances;
    }

    function getocUSDCPrice() external view returns (uint256) {
        uint256 totalSupply = ocUSDC.totalSupply();
        if (totalSupply == 0) return ONE;
        uint256 pool = getPoolValue();
        // Return a WAD price independent of collateral and LP-token decimals.
        return
            (pool * (10 ** ocUSDC.decimals()) * ONE) /
            (totalSupply * (10 ** usdc.decimals()));
    }

    /**
     * @notice Returns the current USDC value of an address's OneClick LP stake.
     * @dev user value = (user ocUSDC / total minted ocUSDC) * total LP
     *      staking. `getPoolValue` excludes user fund deposits.
     */
    function getUserLPStakingValue(address user) public view returns (uint256) {
        uint256 lpShares = ocUSDC.balanceOf(user);
        uint256 totalMintedocUSDC = ocUSDC.totalSupply();

        if (lpShares == 0 || totalMintedocUSDC == 0) return 0;
        return (lpShares * getPoolValue()) / totalMintedocUSDC;
    }

    /// @notice Backwards-compatible naming parity with PerpDex.
    function getUserLPValue(address user) external view returns (uint256) {
        return getUserLPStakingValue(user);
    }

    function depositLP(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be > 0");
        uint256 poolBefore = getPoolValue();
        uint256 totalSupply = ocUSDC.totalSupply();

        uint256 ocUSDCToMint = (totalSupply == 0 || poolBefore == 0)
            ? _initialLpShares(amount)
            : (amount * totalSupply) / poolBefore;

        require(ocUSDCToMint > 0, "Shares must be > 0");

        // User transfers USDC directly (signs transaction)
        require(usdc.transferFrom(msg.sender, address(this), amount), "Transfer failed");

        totalStakedUSDC += amount;
        ocUSDC.mint(msg.sender, ocUSDCToMint);

        if (latestLiquiditySnapshot == 0) {
            _recordLiquiditySnapshot(getPoolValue());
        }

        emit LPDeposit(msg.sender, amount, ocUSDCToMint);
    }

    function _initialLpShares(uint256 collateralAmount) internal view returns (uint256) {
        uint8 collateralDecimals = usdc.decimals();
        uint8 lpTokenDecimals = ocUSDC.decimals();

        if (lpTokenDecimals >= collateralDecimals) {
            return collateralAmount * (10 ** (lpTokenDecimals - collateralDecimals));
        }
        return collateralAmount / (10 ** (collateralDecimals - lpTokenDecimals));
    }

    function withdrawLP(uint256 ocUSDCAmount) external nonReentrant {
        require(ocUSDCAmount > 0, "Amount must be > 0");
        
        uint256 userBalance = ocUSDC.balanceOf(msg.sender);
        require(userBalance >= ocUSDCAmount, "Insufficient ocUSDC");

        uint256 pool = getPoolValue();
        require(pool > 0, "Pool empty");

        uint256 totalSupply = ocUSDC.totalSupply();
        
        uint256 usdcAmount = (ocUSDCAmount * pool) / totalSupply;
        require(usdcAmount > 0, "Amount must be > 0");

        ocUSDC.burn(msg.sender, ocUSDCAmount);
        totalStakedUSDC -= usdcAmount;

        // Transfer USDC directly to user
        require(usdc.transfer(msg.sender, usdcAmount), "Transfer failed");

        emit LPWithdraw(msg.sender, usdcAmount, ocUSDCAmount);
    }

    // ------------------------------------------------------------------
    // VAULT PnL TRACKING
    // ------------------------------------------------------------------
    
    function getVaultPnL() external view returns (int256) {
        return vaultTotalPnL;
    }

    function getVaultStats()
        external
        view
        returns (
            int256 totalPnL,
            uint256 totalProfit,
            uint256 totalLoss,
            uint256 netProfit
        )
    {
        totalPnL = vaultTotalPnL;
        totalProfit = vaultTotalProfit;
        totalLoss = vaultTotalLoss;
        netProfit = vaultTotalProfit > vaultTotalLoss
            ? vaultTotalProfit - vaultTotalLoss
            : 0;
    }

    // ------------------------------------------------------------------
    // SECONDARY VAULT (FEE VAULT)
    // ------------------------------------------------------------------

    function getSecondaryVaultValue() public view returns (uint256) {
        return secondaryVaultBalance;
    }

    function getSecondarySharePrice() external view returns (uint256) {
        if (totalSecondaryShares == 0) return ONE;
        return (secondaryVaultBalance * ONE) / totalSecondaryShares;
    }

    function depositSecondaryVault(uint256 amount) external onlyOwner {
        require(amount > 0, "Amount must be > 0");
        uint256 vaultBefore = secondaryVaultBalance;

        uint256 shares = (totalSecondaryShares == 0 || vaultBefore == 0)
            ? amount
            : (amount * totalSecondaryShares) / vaultBefore;

        require(shares > 0, "Shares must be > 0");

        require(usdc.transferFrom(msg.sender, address(this), amount), "Transfer failed");

        secondaryShares[msg.sender] += shares;
        totalSecondaryShares += shares;
        secondaryVaultBalance += amount;

        emit SecondaryVaultDeposit(msg.sender, amount, shares);
    }

    function withdrawSecondaryVault(uint256 shares) external onlyOwner {
        require(shares > 0, "Shares must be > 0");
        uint256 userShares = secondaryShares[msg.sender];
        require(userShares >= shares, "Insufficient shares");

        uint256 vault = secondaryVaultBalance;
        require(vault > 0, "Vault empty");

        uint256 amount = (shares * vault) / totalSecondaryShares;
        require(amount > 0, "Amount must be > 0");

        secondaryShares[msg.sender] = userShares - shares;
        totalSecondaryShares -= shares;
        secondaryVaultBalance -= amount;

        require(usdc.transfer(msg.sender, amount), "Transfer failed");
        emit SecondaryVaultWithdraw(msg.sender, amount, shares);
    }

    function useSecondaryVaultBackup(uint256 amount) external onlyOwner {
        require(amount > 0, "Amount must be > 0");
        require(secondaryVaultBalance >= amount, "Insufficient secondary vault");

        secondaryVaultBalance -= amount;

        emit VaultBackupUsed(amount, block.timestamp);
    }

    function _collectFeeToSecondaryVault(
        uint256 feeAmount,
        bytes32 positionId,
        address user
    ) internal {
        if (feeAmount > 0) {
            secondaryVaultBalance += feeAmount;
            emit FeeCollected(positionId, user, feeAmount);
        }
    }

    // ------------------------------------------------------------------
    // RISK CONTROLS
    // ------------------------------------------------------------------

    /// @notice Permissionless daily snapshot for the keeper bot.
    function snapshotLiquidityPool() external returns (uint256 poolValue) {
        require(
            block.timestamp >= lastLiquiditySnapshotTimestamp + 1 days,
            "Snapshot not due"
        );
        poolValue = getPoolValue();
        _pauseIfDrawdownExceeded(poolValue);
        _recordLiquiditySnapshot(poolValue);
    }

    /// @notice Allows any caller to trip the drawdown circuit breaker early.
    function checkDrawdown() external returns (bool) {
        _pauseIfDrawdownExceeded(getPoolValue());
        return tradingPaused;
    }

    function resumeTrading() external onlyOwner {
        require(tradingPaused, "Trading active");
        tradingPaused = false;
        emit TradingResumed(msg.sender);
    }

    function getDrawdownThreshold() public view returns (uint256) {
        return (latestLiquiditySnapshot * (BPS - MAX_DRAWDOWN_BPS)) / BPS;
    }

    function getMaxWorstCaseProfit() public view returns (uint256) {
        // Reserve up to 100% of LP capital, independently of the drawdown breaker.
        return getPoolValue();
    }

    function _getMaxOpenMarginPerSide(
        PairInfo storage info,
        uint256 poolValue
    ) internal view returns (uint256) {
        if (totalLiquidityRatio == 0 || info.maxTP == 0) return 0;
        uint256 pairProfitBudget = (poolValue * info.liquidityRatio) / totalLiquidityRatio;
        return ((pairProfitBudget * ONE) / info.maxTP) / 2;
    }

    function _releasePairExposure(Position storage pos) internal {
        PairInfo storage info = _pairInfo[pos.pairs];
        OpenMargins storage margins = pairOpenMargins[pos.pairs];
        if (pos.isLong) {
            info.currentLongOI -= pos.size;
            margins.longMargin -= pos.margin;
        } else {
            info.currentShortOI -= pos.size;
            margins.shortMargin -= pos.margin;
        }
    }

    function _recordLiquiditySnapshot(uint256 poolValue) internal {
        latestLiquiditySnapshot = poolValue;
        lastLiquiditySnapshotTimestamp = block.timestamp;
        emit LiquiditySnapshot(poolValue, block.timestamp);
    }

    function _pauseIfDrawdownExceeded(uint256 poolValue) internal {
        uint256 snapshot = latestLiquiditySnapshot;
        if (!tradingPaused && snapshot > 0 && poolValue <= getDrawdownThreshold()) {
            tradingPaused = true;
            _pauseAllPairs();
            emit TradingPaused(poolValue, getDrawdownThreshold());
        }
    }

    function _pauseAllPairs() internal {
        for (uint256 i = 0; i < pairNames.length; i++) {
            string memory pairs = pairNames[i];
            if (!pairPaused[pairs]) {
                pairPaused[pairs] = true;
                emit PairPaused(pairs, true);
            }
        }
    }

    function _validateWorstCaseProfit(uint256 margin, uint256 maxTP) internal view {
        uint256 additionalExposure = (margin * maxTP) / ONE;
        require(
            totalWorstCaseProfit + additionalExposure <= getMaxWorstCaseProfit(),
            "Exceeds 100% worst-case loss limit"
        );
    }

    function _reserveWorstCaseProfit(
        bytes32 positionId,
        uint256 margin,
        uint256 maxTP
    ) internal {
        uint256 exposure = (margin * maxTP) / ONE;
        positionWorstCaseProfit[positionId] = exposure;
        totalWorstCaseProfit += exposure;
    }

    function _releaseWorstCaseProfit(bytes32 positionId) internal {
        uint256 exposure = positionWorstCaseProfit[positionId];
        if (exposure > 0) {
            totalWorstCaseProfit -= exposure;
            delete positionWorstCaseProfit[positionId];
        }
    }

    function _validatePairMaxTP(uint256 maxTP) internal pure {
        require(maxTP > 0, "Invalid maxTP");
    }

    function _calculateMaxTakeProfitPrice(
        uint256 entryPrice,
        uint256 leverage,
        bool isLong,
        uint256 maxTP
    ) internal pure returns (uint256) {
        uint256 priceDelta = (entryPrice * maxTP) / (ONE * leverage);

        if (isLong) {
            return entryPrice + priceDelta;
        }

        return priceDelta >= entryPrice ? 1 : entryPrice - priceDelta;
    }

    function _resolveAndValidateTakeProfit(
        PairInfo storage info,
        bool isLong,
        uint256 margin,
        uint256 leverage,
        uint256 size,
        uint256 entryPrice,
        uint256 takeProfit
    ) internal view returns (uint256 effectiveTP) {
        effectiveTP = takeProfit == 0
            ? _calculateMaxTakeProfitPrice(
                entryPrice,
                leverage,
                isLong,
                info.maxTP
            )
            : takeProfit;

        if (isLong) {
            require(effectiveTP > entryPrice, "Long TP must be above entry price");
        } else {
            require(effectiveTP < entryPrice, "Short TP must be below entry price");
        }

        uint256 priceDifference = isLong
            ? effectiveTP - entryPrice
            : entryPrice - effectiveTP;
        uint256 takeProfitPnl = (size * priceDifference) / entryPrice;
        uint256 maxPnl = (margin * info.maxTP) / ONE;
        require(takeProfitPnl <= maxPnl, "TP exceeds pair maxTP");
    }

    // ------------------------------------------------------------------
    // OPEN POSITION (Backend Only)
    // ------------------------------------------------------------------

    function openPosition(
        address user,
        string calldata pairs,
        bool isLong,
        uint256 margin,
        uint256 leverage,
        uint256 entryPrice,
        uint256 takeProfit,
        uint256 stopLoss
    ) external onlyAuthorizedBackend nonReentrant whenTradingActive {
        require(margin > 0 && leverage > 0, "Invalid margin or leverage");
        require(margin >= MIN_MARGIN, "Margin too small");
        require(entryPrice > 0, "Invalid entry price");
        
        PairInfo storage info = _pairInfo[pairs];
        require(info.active, "Pair not active");
        require(!pairPaused[pairs], "Pair paused");

        // Validate leverage limits for this pair
        if (leverage < info.minLeverage || leverage > info.maxLeverage) {
            revert InvalidLeverage();
        }

        // Calculate position size
        uint256 netSize = margin * leverage;

        uint256 effectiveTakeProfit = _resolveAndValidateTakeProfit(
            info,
            isLong,
            margin,
            leverage,
            netSize,
            entryPrice,
            takeProfit
        );
        
        // Validate position size limit
        if (netSize > info.maxPositionSize) revert PositionSizeTooLarge();

        // Allocate LP profit capacity by pair weight, split 50/50 by direction.
        // Liquidity checks count open margin; OI is tracked separately as notional.
        uint256 poolValue = getPoolValue();
        require(poolValue > 0, "Pool is empty");
        require(totalLiquidityRatio > 0, "No pairs configured");
        _validateWorstCaseProfit(margin, info.maxTP);
        
        uint256 maxMarginPerSide = _getMaxOpenMarginPerSide(info, poolValue);
        OpenMargins storage margins = pairOpenMargins[pairs];
        
        if (isLong) {
            require(margins.longMargin + margin <= maxMarginPerSide, "Insufficient long liquidity");
        } else {
            require(margins.shortMargin + margin <= maxMarginPerSide, "Insufficient short liquidity");
        }

        // Check user has sufficient available balance (internal balance system)
        uint256 availableBalance = getAvailableBalance(user);
        if (availableBalance < margin) revert InsufficientAvailableBalance();

        // Lock user funds in internal balance
        lockedBalances[user] += margin;
        totalOpenMargin += margin;
        
        // Track notional OI for statistics and open margin for liquidity checks.
        if (isLong) {
            info.currentLongOI += netSize;
            margins.longMargin += margin;
        } else {
            info.currentShortOI += netSize;
            margins.shortMargin += margin;
        }

        _finalizeOpenPosition(
            user,
            pairs,
            isLong,
            margin,
            leverage,
            netSize,
            0,
            entryPrice,
            effectiveTakeProfit,
            stopLoss
        );
    }

    function _finalizeOpenPosition(
        address user,
        string calldata pairs,
        bool isLong,
        uint256 netMargin,
        uint256 leverage,
        uint256 netSize,
        uint256 fees,
        uint256 entryPrice,
        uint256 tp,
        uint256 sl
    ) internal {
        uint256 liquidationPrice = calculateLiquidationPrice(
            entryPrice,
            netSize,
            netMargin,
            isLong
        );

        bytes32 id = keccak256(
            abi.encodePacked(user, block.timestamp, block.number)
        );

        positions[user].push(
            Position(
                id,
                pairs,
                isLong,
                netMargin,
                leverage,
                netSize,
                entryPrice,
                false,
                0,
                0,
                liquidationPrice,
                fees,
                tp,
                sl
            )
        );

        _reserveWorstCaseProfit(id, netMargin, _pairInfo[pairs].maxTP);

        emit OpenPosition(
            id,
            user,
            pairs,
            isLong,
            netMargin,
            leverage,
            netSize,
            entryPrice,
            liquidationPrice,
            fees,
            tp,
            sl
        );
    }

    // ------------------------------------------------------------------
    // MODIFY TP / SL
    // ------------------------------------------------------------------
    function modifyTpSl(
        address user,
        bytes32 positionId,
        uint256 newTP,
        uint256 newSL,
        uint256 currentPrice
    ) external onlyAuthorizedBackend {
        require(currentPrice > 0, "Invalid current price");
        Position[] storage userPositions = positions[user];
        uint256 length = userPositions.length;

        for (uint256 i = 0; i < length; ) {
            Position storage pos = userPositions[i];

            if (pos.id == positionId) {
                require(!pos.isClosed, "Position already closed");

                PairInfo storage info = _pairInfo[pos.pairs];
                uint256 effectiveNewTP = _resolveAndValidateTakeProfit(
                    info,
                    pos.isLong,
                    pos.margin,
                    pos.leverage,
                    pos.size,
                    pos.entryPrice,
                    newTP
                );

                // TP/SL must remain on the correct side of the live price.
                // This prevents a backend from setting an already-triggered
                // level while a pair is paused or the market is moving.
                if (pos.isLong) {
                    require(
                        effectiveNewTP > currentPrice,
                        "Long TP must be above current price"
                    );
                    if (newSL > 0) {
                        require(
                            newSL < currentPrice,
                            "Long SL must be below current price"
                        );
                    }
                } else {
                    require(
                        effectiveNewTP < currentPrice,
                        "Short TP must be below current price"
                    );
                    if (newSL > 0) {
                        require(
                            newSL > currentPrice,
                            "Short SL must be above current price"
                        );
                    }
                }

                if (newSL > 0) {
                    require(effectiveNewTP != newSL, "TP and SL cannot be the same price");
                }
                
                pos.takeProfit = effectiveNewTP;
                pos.stopLoss = newSL;

                emit TPSLModified(positionId, user, effectiveNewTP, newSL);
                return;
            }

            unchecked {
                ++i;
            }
        }

        revert("Position not found");
    }

    // ------------------------------------------------------------------
    // CLOSE POSITION (Backend Only)
    // ------------------------------------------------------------------

    function closePosition(
        address user,
        bytes32 positionId,
        uint256 closePrice
    ) external onlyAuthorizedBackend nonReentrant {
        Position[] storage userPositions = positions[user];

        for (uint256 i = 0; i < userPositions.length; i++) {
            Position storage pos = userPositions[i];

            if (!pos.isClosed && pos.id == positionId) {
                require(closePrice > 0, "Invalid close price");
                _closePosition(user, pos, closePrice, "close");
                return;
            }
        }
        revert("Position not found");
    }

    // ------------------------------------------------------------------
    // TP/SL TRIGGER (Backend Only)
    // ------------------------------------------------------------------

    function triggerTpSl(
        address user,
        bytes32 positionId,
        uint256 currentPrice
    ) external onlyAuthorizedBackend nonReentrant {
        Position[] storage userPositions = positions[user];

        for (uint256 i = 0; i < userPositions.length; i++) {
            Position storage pos = userPositions[i];

            if (!pos.isClosed && pos.id == positionId) {
                require(currentPrice > 0, "Invalid price");

                bool hitTP = false;
                bool hitSL = false;
                string memory status = "";
                uint256 closePrice = currentPrice;

                if (pos.takeProfit > 0) {
                    if (pos.isLong && currentPrice >= pos.takeProfit) {
                        hitTP = true;
                        status = "tp";
                        closePrice = pos.takeProfit;
                    }
                    if (!pos.isLong && currentPrice <= pos.takeProfit) {
                        hitTP = true;
                        status = "tp";
                        closePrice = pos.takeProfit;
                    }
                }

                if (pos.stopLoss > 0) {
                    if (pos.isLong && currentPrice <= pos.stopLoss) {
                        hitSL = true;
                        status = "sl";
                        closePrice = pos.stopLoss;
                    }
                    if (!pos.isLong && currentPrice >= pos.stopLoss) {
                        hitSL = true;
                        status = "sl";
                        closePrice = pos.stopLoss;
                    }
                }

                require(hitTP || hitSL, "No TP/SL triggered");

                _closePosition(user, pos, closePrice, status);
                return;
            }
        }

        revert("Position not found");
    }

    // ------------------------------------------------------------------
    // LIQUIDATION (Backend Only)
    // ------------------------------------------------------------------

    function liquidate(
        address user,
        bytes32 positionId,
        uint256 price
    ) external onlyAuthorizedBackend nonReentrant {
        Position[] storage userPositions = positions[user];

        for (uint256 i = 0; i < userPositions.length; i++) {
            Position storage pos = userPositions[i];

            if (!pos.isClosed && pos.id == positionId) {
                require(price > 0, "Invalid price");
                require(!pairPaused[pos.pairs], "Pair paused");

                int256 pnl = pos.isLong
                    ? (int256(pos.size) * (int256(price) - int256(pos.entryPrice))) / int256(pos.entryPrice)
                    : (int256(pos.size) * (int256(pos.entryPrice) - int256(price))) / int256(pos.entryPrice);

                int256 equity = int256(pos.margin) + pnl;

                require(equity <= 0, "Not liquidatable");

                // Unlock user funds from internal balance
                if (lockedBalances[user] >= pos.margin) {
                    lockedBalances[user] -= pos.margin;
                } else {
                    lockedBalances[user] = 0;
                }

                if (totalOpenMargin >= pos.margin) {
                    totalOpenMargin -= pos.margin;
                } else {
                    totalOpenMargin = 0;
                }

                _releasePairExposure(pos);

                // Deduct full margin from user's internal balance (100% loss)
                if (userBalances[user] >= pos.margin) {
                    userBalances[user] -= pos.margin;
                    totalUserBalances -= pos.margin;
                } else {
                    totalUserBalances -= userBalances[user];
                    userBalances[user] = 0;
                }

                // Track vault PnL - vault gains the full margin
                int256 vaultPnL = int256(pos.margin);
                vaultTotalPnL += vaultPnL;
                vaultTotalProfit += pos.margin;

                pos.isClosed = true;
                pos.closePrice = price;
                pos.payout = 0;

                _releaseWorstCaseProfit(pos.id);
                _pauseIfDrawdownExceeded(getPoolValue());

                emit ClosePosition(pos.id, user, price, 0, 0, "liquidate");
                return;
            }
        }

        revert("Position not found");
    }

    // ------------------------------------------------------------------
    // INTERNAL CLOSE LOGIC
    // ------------------------------------------------------------------

    function _closePosition(
        address user,
        Position storage pos,
        uint256 price,
        string memory status
    ) internal {
        require(!pairPaused[pos.pairs], "Pair paused");
        int256 pnl = pos.isLong
            ? (int256(pos.size) * (int256(price) - int256(pos.entryPrice))) / int256(pos.entryPrice)
            : (int256(pos.size) * (int256(pos.entryPrice) - int256(price))) / int256(pos.entryPrice);

        int256 cappedPnl = pnl;
        if (cappedPnl > 0) {
            // Keep the cap fixed to the liability reserved when the position
            // opened; a later pair maxTP update must not increase LP risk.
            int256 maxPnl = int256(positionWorstCaseProfit[pos.id]);
            if (cappedPnl > maxPnl) cappedPnl = maxPnl;
        }

        int256 rawPayout = int256(pos.margin) + cappedPnl;
        uint256 payout = rawPayout > 0 ? uint256(rawPayout) : 0;

        // Charge only realized profit: 1.5% to the platform, 2% retained by LPs.
        uint256 closeFee = 0;
        uint256 platformFee = 0;
        if (payout > pos.margin) {
            uint256 profit = payout - pos.margin;
            closeFee = (profit * WINNING_FEE_BPS) / BPS;
            platformFee = (profit * PLATFORM_FEE_BPS) / BPS;
            payout -= closeFee;

            // Rounding dust stays with LPs; only the platform share is reserved.
            _collectFeeToSecondaryVault(platformFee, pos.id, user);
            emit ProfitFeeSplit(pos.id, platformFee, closeFee - platformFee);
        }

        // Net LP asset change includes retained LP fees and excludes platform fees.
        int256 vaultPnL = int256(pos.margin) - int256(payout) - int256(platformFee);
        vaultTotalPnL += vaultPnL;
        if (vaultPnL > 0) vaultTotalProfit += uint256(vaultPnL);
        else if (vaultPnL < 0) vaultTotalLoss += uint256(-vaultPnL);

        // Unlock user funds from internal balance
        if (lockedBalances[user] >= pos.margin) {
            lockedBalances[user] -= pos.margin;
        } else {
            lockedBalances[user] = 0;
        }

        if (totalOpenMargin >= pos.margin) {
            totalOpenMargin -= pos.margin;
        } else {
            totalOpenMargin = 0;
        }

        _releasePairExposure(pos);

        // Update user internal balance with payout
        // If user made profit, add to balance; if loss, deduct from balance
        if (payout > pos.margin) {
            // User made profit - add the profit to their balance
            uint256 profit = payout - pos.margin;
            userBalances[user] += profit;
            totalUserBalances += profit;
        } else if (payout < pos.margin) {
            // User made loss - deduct the loss from their balance
            uint256 loss = pos.margin - payout;
            if (userBalances[user] >= loss) {
                userBalances[user] -= loss;
                totalUserBalances -= loss;
            } else {
                totalUserBalances -= userBalances[user];
                userBalances[user] = 0;
            }
        }
        // If payout == margin, no change to balance (break even)

        pos.isClosed = true;
        pos.closePrice = price;
        pos.payout = payout;

        _releaseWorstCaseProfit(pos.id);
        _pauseIfDrawdownExceeded(getPoolValue());

        emit ClosePosition(pos.id, user, price, payout, closeFee, status);
    }

    // ------------------------------------------------------------------
    // ADMIN EMERGENCY CLOSE ALL
    // ------------------------------------------------------------------

    /// @notice Closes eligible open positions using owner-reviewed backend prices.
    /// @dev OneClickPerpDex has no on-chain oracle, so the owner explicitly
    /// supplies a price for each pair to be closed. Positions in pairs omitted
    /// from `pairs` are intentionally skipped.
    /// @param pairs Pair names whose positions may be emergency-closed.
    /// @param prices Close prices corresponding one-to-one with `pairs`.
    function closeAllPositions(
        string[] calldata pairs,
        uint256[] calldata prices
    ) external onlyOwner nonReentrant {
        require(pairs.length == prices.length, "Pairs/prices length mismatch");
        require(pairs.length > 0, "No prices supplied");

        for (uint256 p = 0; p < pairs.length; p++) {
            require(prices[p] > 0, "Invalid close price");
            require(bytes(_pairInfo[pairs[p]].name).length > 0, "Pair not found");

            for (uint256 duplicate = 0; duplicate < p; duplicate++) {
                require(
                    keccak256(bytes(pairs[duplicate])) != keccak256(bytes(pairs[p])),
                    "Duplicate pair"
                );
            }
        }

        for (uint256 u = 0; u < allUsers.length; u++) {
            address user = allUsers[u];
            Position[] storage userPositions = positions[user];

            for (uint256 i = 0; i < userPositions.length; i++) {
                Position storage pos = userPositions[i];
                if (pos.isClosed || pairPaused[pos.pairs]) continue;

                for (uint256 p = 0; p < pairs.length; p++) {
                    if (keccak256(bytes(pos.pairs)) == keccak256(bytes(pairs[p]))) {
                        _closePosition(user, pos, prices[p], "close");
                        break;
                    }
                }
            }
        }

        emit AllPositionsClosed(msg.sender, block.timestamp);
    }

    /// @notice Legacy BTC/ETH/SOL emergency close entrypoint.
    /// @dev Retained for existing integrations. New integrations should call
    /// the generic overloaded `closeAllPositions(string[],uint256[])` above.
    function closeAllPositions(
        uint256 btcPrice,
        uint256 ethPrice,
        uint256 solPrice
    ) external onlyOwner {
        for (uint256 u = 0; u < allUsers.length; u++) {
            address user = allUsers[u];
            Position[] storage userPositions = positions[user];

            for (uint256 i = 0; i < userPositions.length; i++) {
                Position storage pos = userPositions[i];

                if (!pos.isClosed && !pairPaused[pos.pairs]) {
                    uint256 price = 0;

                    if (keccak256(bytes(pos.pairs)) == keccak256(bytes("BTC_USD"))) {
                        price = btcPrice;
                    } else if (keccak256(bytes(pos.pairs)) == keccak256(bytes("ETH_USD"))) {
                        price = ethPrice;
                    } else if (keccak256(bytes(pos.pairs)) == keccak256(bytes("SOL_USD"))) {
                        price = solPrice;
                    }

                    if (price > 0) {
                        _closePosition(user, pos, price, "close");
                    }
                }
            }
        }

        emit AllPositionsClosed(msg.sender, block.timestamp);
    }

    // ------------------------------------------------------------------
    // ADMIN FUNCTIONS - Pair Configuration
    // ------------------------------------------------------------------

    /**
     * @notice Update pair configuration (owner only)
     * @param pairs Trading pair name (e.g., "BTC_USD")
     * @param liquidityRatio Liquidity allocation weight (e.g., 10 for BTC, 5 for ETH)
     * @param maxPositionSize Max position size in USDC (e.g., 5000e6 = 5000 USDC)
     * @param minLeverage Minimum leverage allowed (e.g., 2 = 2x)
     * @param maxLeverage Maximum leverage allowed (e.g., 100 = 100x)
     */
    function updatePairConfig(
        string calldata pairs,
        uint256 liquidityRatio,
        uint256 maxPositionSize,
        uint256 minLeverage,
        uint256 maxLeverage
    ) external onlyOwner {
        PairInfo storage info = _pairInfo[pairs];
        require(bytes(info.name).length > 0, "Pair does not exist");
        if (
            minLeverage == 0 ||
            maxLeverage == 0 ||
            minLeverage > maxLeverage
        ) revert InvalidLeverage();
        require(liquidityRatio > 0, "Invalid liquidity ratio");
        if (maxPositionSize == 0) revert PositionSizeTooLarge();
        _validatePairMaxTP(info.maxTP);

        // Update total ratio
        totalLiquidityRatio = totalLiquidityRatio - info.liquidityRatio + liquidityRatio;
        
        info.liquidityRatio = liquidityRatio;
        info.maxPositionSize = maxPositionSize;
        info.minLeverage = minLeverage;
        info.maxLeverage = maxLeverage;

        emit PairConfigUpdated(pairs, liquidityRatio, maxPositionSize, minLeverage, maxLeverage);
    }

    /**
     * @notice Update a pair's maximum gross profit.
     * @param maxTP 18-decimal profit-on-margin ratio
     *              (1e18 = 100%, 5e18 = 500%)
     */
    function updatePairMaxTP(
        string calldata pairs,
        uint256 maxTP
    ) external onlyOwner {
        PairInfo storage info = _pairInfo[pairs];
        require(bytes(info.name).length > 0, "Pair does not exist");
        _validatePairMaxTP(maxTP);

        info.maxTP = maxTP;

        emit PairMaxTPUpdated(pairs, maxTP);
    }

    /**
     * @notice Update pair active status (owner only)
     * @param pairs Trading pair name
     * @param active True to activate, false to deactivate
     */
    function setPairActive(string calldata pairs, bool active) external onlyOwner {
        PairInfo storage info = _pairInfo[pairs];
        require(bytes(info.name).length > 0, "Pair does not exist");
        
        info.active = active;
        emit PairStatus(pairs, active);
    }

    /// @notice Freezes every trading action for one pair except TP/SL edits.
    function setPairPaused(string calldata pairs, bool paused) external onlyOwner {
        require(bytes(_pairInfo[pairs].name).length > 0, "Pair does not exist");
        pairPaused[pairs] = paused;
        emit PairPaused(pairs, paused);
    }

    /// @notice Owner emergency action to pause every configured market.
    function pauseAllPairs() external onlyOwner {
        _pauseAllPairs();
    }

    /**
     * @notice Add a new trading pair (owner only)
     * @param pairs Trading pair name
     * @param liquidityRatio Liquidity allocation weight
     * @param maxPositionSize Max position size in USDC
     * @param minLeverage Minimum leverage
     * @param maxLeverage Maximum leverage
     * @param maxTP Maximum profit ratio (1e18 = 100% of margin)
     */
    function addPair(
        string calldata pairs,
        uint256 liquidityRatio,
        uint256 maxPositionSize,
        uint256 minLeverage,
        uint256 maxLeverage,
        uint256 maxTP
    ) external onlyOwner {
        require(bytes(_pairInfo[pairs].name).length == 0, "Pair already exists");
        if (
            minLeverage == 0 ||
            maxLeverage == 0 ||
            minLeverage > maxLeverage
        ) revert InvalidLeverage();
        require(liquidityRatio > 0, "Invalid liquidity ratio");
        if (maxPositionSize == 0) revert PositionSizeTooLarge();

        _addPair(pairs, liquidityRatio, maxPositionSize, minLeverage, maxLeverage, maxTP);
    }

    event PairConfigUpdated(
        string pairs,
        uint256 liquidityRatio,
        uint256 maxPositionSize,
        uint256 minLeverage,
        uint256 maxLeverage
    );
    event PairMaxTPUpdated(string pairs, uint256 maxTP);

    // ------------------------------------------------------------------
    // HELPERS
    // ------------------------------------------------------------------

    function calculateLiquidationPrice(
        uint256 entryPrice,
        uint256 size,
        uint256 margin,
        bool isLong
    ) internal pure returns (uint256) {
        uint256 priceChange = (entryPrice * margin) / size;
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

    // ------------------------------------------------------------------
    // VIEW FUNCTIONS
    // ------------------------------------------------------------------

    function getUserPositions(address user) external view returns (Position[] memory) {
        return positions[user];
    }

    function isPositionLiquidatable(
        address user,
        bytes32 positionId,
        uint256 currentPrice
    ) external view returns (bool) {
        Position[] memory userPositions = positions[user];

        for (uint256 i = 0; i < userPositions.length; i++) {
            if (userPositions[i].id == positionId && !userPositions[i].isClosed) {
                Position memory pos = userPositions[i];

                int256 pnl = pos.isLong
                    ? (int256(pos.size) * (int256(currentPrice) - int256(pos.entryPrice))) / int256(pos.entryPrice)
                    : (int256(pos.size) * (int256(pos.entryPrice) - int256(currentPrice))) / int256(pos.entryPrice);

                int256 equity = int256(pos.margin) + pnl;
                return equity <= 0;
            }
        }

        return false;
    }

    function getPositionEquity(
        address user,
        bytes32 positionId,
        uint256 currentPrice
    ) external view returns (int256) {
        Position[] memory userPositions = positions[user];

        for (uint256 i = 0; i < userPositions.length; i++) {
            if (userPositions[i].id == positionId && !userPositions[i].isClosed) {
                Position memory pos = userPositions[i];

                int256 pnl = pos.isLong
                    ? (int256(pos.size) * (int256(currentPrice) - int256(pos.entryPrice))) / int256(pos.entryPrice)
                    : (int256(pos.size) * (int256(pos.entryPrice) - int256(currentPrice))) / int256(pos.entryPrice);

                return int256(pos.margin) + pnl;
            }
        }

        revert("Position not found");
    }

    function getUserInfo(address user)
        external
        view
        returns (
            uint256 totalBalance,
            uint256 lockedBalance,
            uint256 availableBalance,
            uint256 activePositions
        )
    {
        totalBalance = userBalances[user];
        lockedBalance = lockedBalances[user];
        availableBalance = getAvailableBalance(user);

        Position[] memory userPositions = positions[user];
        for (uint256 i = 0; i < userPositions.length; i++) {
            if (!userPositions[i].isClosed) {
                activePositions++;
            }
        }
    }

    function getAllPairs() external view returns (PairInfo[] memory pairs) {
        pairs = new PairInfo[](pairNames.length);
        for (uint256 i; i < pairs.length; i++) {
            pairs[i] = pairInfo(pairNames[i]);
        }
    }

    function getAllUsers() external view returns (address[] memory) {
        return allUsers;
    }

    function getocUSDCAddress() external view returns (address) {
        return address(ocUSDC);
    }

    function getUSDCAddress() external view returns (address) {
        return address(usdc);
    }

    /// @notice Pair configuration with available liquidity calculated from current LP capital.
    function pairInfo(string memory pairs) public view returns (PairInfo memory info) {
        info = _pairInfo[pairs];
        uint256 longMargin;
        uint256 shortMargin;
        (,, longMargin, shortMargin,,,, info.availableLiquidity) = getAvailableLiquidity(pairs);
        info.usedLiquidity = longMargin + shortMargin;
    }

    function allPairs(uint256 index) external view returns (PairInfo memory) {
        return pairInfo(pairNames[index]);
    }

    /// @notice Open interest statistics in leveraged notional collateral units.
    function getOpenInterest(string calldata pairs)
        external view returns (uint256 longOI, uint256 shortOI, uint256 totalOI)
    {
        PairInfo storage info = _pairInfo[pairs];
        longOI = info.currentLongOI;
        shortOI = info.currentShortOI;
        totalOI = longOI + shortOI;
    }

    /**
     * @notice Available Liquidity derived from the pair's allocation weight and maxTP.
     * @param pairs Trading pair name (e.g., "BTC_USD")
     * @return allocatedLiquidity Current LP capital allocated to this pair
     * @return maxMarginPerSide Maximum open margin per side at the current pair maxTP
     * @return currentLongMargin Current open long margin
     * @return currentShortMargin Current open short margin
     * @return availableLongLiquidity Additional long margin, capped by global profit capacity
     * @return availableShortLiquidity Additional short margin, capped by global profit capacity
     * @return maxPositionSize Maximum leveraged notional size per position
     * @return availableLiquidity Combined remaining margin capacity, capped by global profit capacity
     */
    function getAvailableLiquidity(string memory pairs)
        public
        view
        returns (
            uint256 allocatedLiquidity,
            uint256 maxMarginPerSide,
            uint256 currentLongMargin,
            uint256 currentShortMargin,
            uint256 availableLongLiquidity,
            uint256 availableShortLiquidity,
            uint256 maxPositionSize,
            uint256 availableLiquidity
        )
    {
        PairInfo storage info = _pairInfo[pairs];
        OpenMargins storage margins = pairOpenMargins[pairs];
        
        uint256 poolValue = getPoolValue();
        
        allocatedLiquidity = totalLiquidityRatio > 0 ? (poolValue * info.liquidityRatio) / totalLiquidityRatio : 0;
        maxMarginPerSide = _getMaxOpenMarginPerSide(info, poolValue);
        
        currentLongMargin = margins.longMargin;
        currentShortMargin = margins.shortMargin;
        
        availableLongLiquidity = maxMarginPerSide > currentLongMargin ? maxMarginPerSide - currentLongMargin : 0;
        availableShortLiquidity = maxMarginPerSide > currentShortMargin ? maxMarginPerSide - currentShortMargin : 0;

        uint256 remainingProfit = poolValue > totalWorstCaseProfit ? poolValue - totalWorstCaseProfit : 0;
        uint256 availableMargin = info.maxTP > 0 ? (remainingProfit * ONE) / info.maxTP : 0;
        if (availableLongLiquidity > availableMargin) availableLongLiquidity = availableMargin;
        if (availableShortLiquidity > availableMargin) availableShortLiquidity = availableMargin;
        availableLiquidity = availableLongLiquidity + availableShortLiquidity;
        if (availableLiquidity > availableMargin) availableLiquidity = availableMargin;
        
        maxPositionSize = info.maxPositionSize;
    }

}

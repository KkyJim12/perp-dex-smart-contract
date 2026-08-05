// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "lib/pyth-sdk-solidity/PythStructs.sol";
import "lib/pyth-sdk-solidity/IPyth.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

interface IppUSDC {
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
}

contract PerpDex {
    IPyth public pyth;
    ERC20 public usdc;
    IppUSDC public ppUSDC; // LP token

    address public owner;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not admin");
        _;
    }

    uint256 public constant ONE = 1e18;

    uint256 public constant WINNING_FEE_BPS = 200; // 2% fee on winning positions only
    uint256 public constant SPREAD_BPS = 0;
    uint256 public constant MAINTENANCE_MARGIN_RATIO = 0;
    uint256 public constant LIQUIDATION_REWARD_RATIO = 0;

    uint256 public constant MAX_DAILY_FUNDING_BPS = 0; // Disabled funding
    uint256 public constant FUNDING_MAX_PER_SEC = 0; // Disabled funding

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
        uint256 oiRatio; // OI ratio weight (e.g., BTC=10, ETH=5, SOL=3)
        uint256 maxPositionSize; // Max size per position in USDC (e.g., 5000e6 = 5000 USDC)
        uint256 minLeverage; // Minimum leverage allowed (e.g., 2 = 2x)
        uint256 maxLeverage; // Maximum leverage allowed (e.g., 100 = 100x)
        uint256 maxTP; // Maximum gross profit as a ratio of margin (1e18 = 100%)
    }

    mapping(address => Position[]) public positions;
    mapping(address => string) public username;
    mapping(string => address) public usernameTaken;
    mapping(string => PairFunding) public pairFunding;
    mapping(string => PairInfo) public pairInfo;
    mapping(string => bool) public pairPaused;

    PairInfo[] public allPairs;
    address[] public allUsers;

    uint256 public totalOpenMargin;
    uint256 public totalOIRatio; // Sum of all pair OI ratios

    // Sum of every open position's maximum allowed profit. Unlike notional
    // OI, this is the amount LPs can actually lose if every TP is hit.
    uint256 public totalWorstCaseProfit;
    mapping(bytes32 => uint256) public positionWorstCaseProfit;

    uint256 public constant MAX_DRAWDOWN_BPS = 3_000; // 30%
    uint256 public constant BPS = 10_000;
    bool public tradingPaused;
    uint256 public latestLiquiditySnapshot;
    uint256 public lastLiquiditySnapshotTimestamp;

    // Secondary Vault (Fee Vault) - serves as backup for main vault
    uint256 public totalSecondaryShares;
    mapping(address => uint256) public secondaryShares;
    uint256 public secondaryVaultBalance; // Accumulated fees

    // Main Vault PnL Tracking
    int256 public vaultTotalPnL; // Cumulative vault profit/loss
    uint256 public vaultTotalProfit; // Total profit earned by vault
    uint256 public vaultTotalLoss; // Total loss taken by vault

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
        uint256 closeFee,
        string status
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
    event PairPaused(string name, bool paused);
    event OwnershipTransferred(
        address indexed oldOwner,
        address indexed newOwner
    );
    event AllPositionsClosed(address indexed admin, uint256 timestamp);
    event LPDeposit(address indexed user, uint256 amount, uint256 shares);
    event LPWithdraw(address indexed user, uint256 amount, uint256 shares);
    event StakingDebug(
        address indexed user,
        string action,
        uint256 amount,
        uint256 shares,
        uint256 totalSupply,
        uint256 tvl,
        uint256 userPercentage
    );
    event TPSLModified(
        bytes32 indexed positionId,
        address indexed user,
        uint256 newTakeProfit,
        uint256 newStopLoss
    );
    event TPSLValidated(
        bytes32 indexed positionId,
        address indexed user,
        uint256 currentPrice,
        uint256 takeProfit,
        uint256 stopLoss,
        bool isLong,
        string action
    );
    event FeeCollected(
        bytes32 indexed positionId,
        address indexed user,
        uint256 feeAmount
    );
    event SecondaryVaultDeposit(
        address indexed user,
        uint256 amount,
        uint256 shares
    );
    event SecondaryVaultWithdraw(
        address indexed user,
        uint256 amount,
        uint256 shares
    );
    event VaultBackupUsed(uint256 amount, uint256 timestamp);
    event SLExecutedByLiquidationBot(
        bytes32 indexed positionId,
        address indexed user,
        address indexed liquidator,
        uint256 slPrice,
        uint256 payout,
        string reason
    );
    event LiquiditySnapshot(uint256 poolValue, uint256 timestamp);
    event TradingPaused(uint256 poolValue, uint256 drawdownThreshold);
    event TradingResumed(address indexed admin);

    constructor(address _usdc, address _pyth, address _ppUSDC) {
        _initialize(_usdc, _pyth, _ppUSDC, msg.sender);
    }

    function _initialize(
        address _usdc,
        address _pyth,
        address _ppUSDC,
        address initialOwner
    ) internal {
        require(
            _usdc != address(0) && _pyth != address(0) && _ppUSDC != address(0),
            "Invalid address"
        );
        require(initialOwner != address(0), "Invalid owner");
        usdc = ERC20(_usdc);
        pyth = IPyth(_pyth);
        ppUSDC = IppUSDC(_ppUSDC);
        owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);
    }

    receive() external payable {}

    modifier whenTradingActive() {
        require(!tradingPaused, "Trading paused");
        _;
    }

    function _addPair(
        string memory pairs,
        bytes32 pythTokenId,
        uint256 oiRatio,
        uint256 maxPositionSize,
        uint256 minLeverage,
        uint256 maxLeverage,
        uint256 maxTP
    ) internal {
        _validatePairMaxTP(maxTP, maxLeverage);
        pairInfo[pairs] = PairInfo(
            pairs,
            pythTokenId,
            true,
            oiRatio,
            maxPositionSize,
            minLeverage,
            maxLeverage,
            maxTP
        );
        allPairs.push(pairInfo[pairs]);
        totalOIRatio += oiRatio; // Add to total ratio sum
        emit PairAdded(pairs, pythTokenId);
        emit PairStatus(pairs, true);
    }

    // ------------------------------------------------------------------
    // Register Username
    // ------------------------------------------------------------------
    function registerUsername(string calldata newName) external {
        require(bytes(newName).length > 0, "Empty username");
        require(usernameTaken[newName] == address(0), "Name already used");

        string memory oldName = username[msg.sender];

        // If user already had a username, free it
        if (bytes(oldName).length > 0) {
            usernameTaken[oldName] = address(0);
        } else {
            // New user → add to allUsers
            allUsers.push(msg.sender);
        }

        // Assign new username
        username[msg.sender] = newName;
        usernameTaken[newName] = msg.sender;

        emit RegisterUser(msg.sender, newName);
    }

    // ------------------------------------------------------------------
    // LP POOL
    // ------------------------------------------------------------------

    function getPoolValue() public view returns (uint256) {
        uint256 contractBalance = usdc.balanceOf(address(this));
        
        // Subtract reserved amounts (trader margins + secondary vault)
        uint256 reserved = totalOpenMargin + secondaryVaultBalance;
        
        if (contractBalance <= reserved) {
            return 0; // Pool is empty or negative
        }
        
        // For now, use simple calculation without PnL tracking
        // This represents the actual USDC available to LPs
        return contractBalance - reserved;
    }

    // Alternative function that includes PnL (for future use)
    function getPoolValueWithPnL() public view returns (uint256) {
        uint256 basePoolValue = getPoolValue();
        
        // Add/subtract unrealized PnL from vault perspective
        if (vaultTotalPnL >= 0) {
            return basePoolValue + uint256(vaultTotalPnL);
        } else {
            uint256 loss = uint256(-vaultTotalPnL);
            return basePoolValue > loss ? basePoolValue - loss : 0;
        }
    }

    function getppUSDCPrice() external view returns (uint256) {
        uint256 totalSupply = ppUSDC.totalSupply();
        if (totalSupply == 0) return ONE; // 1:1 ratio for first deposit
        
        uint256 poolValue = getPoolValue();
        if (poolValue == 0) return 0; // Pool is empty
        
        // Return a WAD price independent of collateral and LP-token decimals.
        return
            (poolValue * (10 ** ppUSDC.decimals()) * ONE) /
            (totalSupply * (10 ** usdc.decimals()));
    }

    /**
     * @notice Returns the current USDC value of an address's LP position.
     * @dev This is the amount returned if the address withdraws all of its
     *      current ppUSDC. It is a current value, not historical deposits.
    */
    function getUserLPValue(address user) external view returns (uint256) {
        uint256 lpShares = ppUSDC.balanceOf(user);

        if (lpShares == 0) return 0;
        return (lpShares * getPoolValue()) / ppUSDC.totalSupply();
    }

    // Helper function to calculate how much ppUSDC user would get for a deposit
    function calculateDepositShares(uint256 depositAmount) external view returns (uint256) {
        require(depositAmount > 0, "Amount must be > 0");
        
        uint256 totalSupply = ppUSDC.totalSupply();
        uint256 currentTVL = getPoolValue();
        
        if (totalSupply == 0) {
            return _initialLpShares(depositAmount);
        } else {
            require(currentTVL > 0, "Pool has no value");
            return (depositAmount * totalSupply) / currentTVL;
        }
    }

    // Helper function to calculate how much USDC user would get for burning ppUSDC
    function calculateWithdrawAmount(uint256 ppUSDCAmount) external view returns (uint256) {
        require(ppUSDCAmount > 0, "Amount must be > 0");
        
        uint256 totalSupply = ppUSDC.totalSupply();
        require(totalSupply > 0, "No ppUSDC in circulation");
        
        uint256 currentTVL = getPoolValue();
        require(currentTVL > 0, "Pool has no value");
        
        return (ppUSDCAmount * currentTVL) / totalSupply;
    }

    function depositLP(uint256 amount) external {
        require(amount > 0, "Amount must be > 0");
        
        uint256 totalSupply = ppUSDC.totalSupply();
        uint256 currentTVL = getPoolValue();
        
        uint256 ppUSDCToMint;
        
        if (totalSupply == 0) {
            // Normalize collateral to the LP token's decimals. With both
            // USDC and ppUSDC at 6 decimals, 10,000 USDC mints 10,000 ppUSDC.
            ppUSDCToMint = _initialLpShares(amount);
        } else {
            // Subsequent deposits: ppUSDC_to_mint = (deposit_amount * total_ppUSDC_supply) / current_TVL
            require(currentTVL > 0, "Pool has no value");
            ppUSDCToMint = (amount * totalSupply) / currentTVL;
        }

        require(ppUSDCToMint > 0, "Shares must be > 0");

        // Transfer USDC from user to contract
        require(
            usdc.transferFrom(msg.sender, address(this), amount),
            "Transfer failed"
        );

        // Mint ppUSDC tokens to user
        ppUSDC.mint(msg.sender, ppUSDCToMint);

        // Set a baseline when the pool first receives liquidity. Subsequent
        // snapshots are intentionally keeper-triggered once per day.
        if (latestLiquiditySnapshot == 0) {
            _recordLiquiditySnapshot(getPoolValue());
        }

        // Calculate user's new percentage
        uint256 newTotalSupply = ppUSDC.totalSupply();
        uint256 userPercentage = (ppUSDCToMint * 10000) / newTotalSupply;

        emit LPDeposit(msg.sender, amount, ppUSDCToMint);
        emit StakingDebug(
            msg.sender,
            "deposit",
            amount,
            ppUSDCToMint,
            newTotalSupply,
            currentTVL + amount,
            userPercentage
        );
    }

    function withdrawLP(uint256 ppUSDCAmount) external {
        require(ppUSDCAmount > 0, "Amount must be > 0");
        
        uint256 userBalance = ppUSDC.balanceOf(msg.sender);
        require(userBalance >= ppUSDCAmount, "Insufficient ppUSDC");

        uint256 totalSupply = ppUSDC.totalSupply();
        require(totalSupply > 0, "No ppUSDC in circulation");
        
        uint256 currentTVL = getPoolValue();
        require(currentTVL > 0, "Pool has no value");
        
        // Calculate USDC to return: USDC_to_return = (ppUSDC_to_burn * current_TVL) / total_ppUSDC_supply
        uint256 usdcAmount = (ppUSDCAmount * currentTVL) / totalSupply;
        require(usdcAmount > 0, "Amount must be > 0");
        
        // SAFETY CHECK: Ensure withdrawal amount is reasonable
        // User should not get more USDC than their percentage of the pool
        uint256 userPercentage = (ppUSDCAmount * 10000) / totalSupply; // Basis points (10000 = 100%)
        uint256 maxExpectedUSDC = (currentTVL * userPercentage) / 10000;
        
        // Allow small rounding differences (0.1% tolerance)
        uint256 tolerance = maxExpectedUSDC / 1000;
        require(
            usdcAmount <= maxExpectedUSDC + tolerance,
            "Withdrawal amount exceeds expected share"
        );
        
        // Additional safety check: ensure contract has enough USDC
        uint256 contractBalance = usdc.balanceOf(address(this));
        require(contractBalance >= usdcAmount, "Insufficient contract balance");

        // Burn ppUSDC from user
        ppUSDC.burn(msg.sender, ppUSDCAmount);

        // Transfer USDC to user
        require(usdc.transfer(msg.sender, usdcAmount), "Transfer failed");

        emit LPWithdraw(msg.sender, usdcAmount, ppUSDCAmount);
        emit StakingDebug(
            msg.sender,
            "withdraw",
            usdcAmount,
            ppUSDCAmount,
            totalSupply - ppUSDCAmount,
            currentTVL - usdcAmount,
            userPercentage
        );
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
    // SECONDARY VAULT (FEE VAULT) - Backup for Main Vault
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

        require(
            usdc.transferFrom(msg.sender, address(this), amount),
            "Transfer failed"
        );

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

    // Use secondary vault to backup main vault in emergency
    function useSecondaryVaultBackup(uint256 amount) external onlyOwner {
        require(amount > 0, "Amount must be > 0");
        require(
            secondaryVaultBalance >= amount,
            "Insufficient secondary vault"
        );

        secondaryVaultBalance -= amount;
        // Amount stays in contract, now available for main vault

        emit VaultBackupUsed(amount, block.timestamp);
    }

    // Collect fees to secondary vault (internal function)
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

    function _initialLpShares(uint256 collateralAmount) internal view returns (uint256) {
        uint8 collateralDecimals = usdc.decimals();
        uint8 lpTokenDecimals = ppUSDC.decimals();

        if (lpTokenDecimals >= collateralDecimals) {
            return collateralAmount * (10 ** (lpTokenDecimals - collateralDecimals));
        }
        return collateralAmount / (10 ** (collateralDecimals - lpTokenDecimals));
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
        return (getPoolValue() * MAX_DRAWDOWN_BPS) / BPS;
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
        for (uint256 i = 0; i < allPairs.length; i++) {
            string memory pairs = allPairs[i].name;
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
            "Exceeds 30% worst-case loss limit"
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

    // ------------------------------------------------------------------
    // FUNDING (DISABLED - SET TO 0)
    // ------------------------------------------------------------------

    function updateFunding(string calldata pairs) public {
        _accrueFunding(pairs);
        PairFunding storage pf = pairFunding[pairs];
        emit FundingUpdated(
            pairs,
            pf.growth, // Always 0 since funding is disabled
            pf.oiLong,
            pf.oiShort,
            block.timestamp
        );
    }

    function _accrueFunding(string memory pairs) internal {
        PairFunding storage pf = pairFunding[pairs];
        
        // Update timestamp but don't calculate funding since it's disabled
        if (pf.lastUpdate == 0) {
            pf.lastUpdate = block.timestamp;
        } else {
            pf.lastUpdate = block.timestamp;
        }
        
        // Funding growth remains 0 since FUNDING_MAX_PER_SEC = 0
        // pf.growth stays unchanged (always 0 for new pairs)
    }

    // ------------------------------------------------------------------
    // ORACLE HELPERS
    // ------------------------------------------------------------------

    function _updateAndGetPythPrice(
        bytes[] calldata priceUpdateData,
        bytes32 priceId
    ) internal returns (PythStructs.Price memory) {
        uint256 fee = pyth.getUpdateFee(priceUpdateData);
        require(msg.value >= fee);
        pyth.updatePriceFeeds{value: fee}(priceUpdateData);

        PythStructs.Price memory p = pyth.getPrice(priceId);
        require(p.price > 0);
        return p;
    }

    /**
     * @notice Calculate the furthest TP price allowed by a pair's profit cap.
     * @dev maxTP is an 18-decimal profit-on-margin ratio (1e18 = 100%).
     *      A short cannot earn more than leverage * margin even if price reaches
     *      zero, so its lowest representable TP is one price unit.
     */
    function _calculateMaxTakeProfitPrice(
        uint256 entryPrice,
        uint256 leverage,
        bool isLong,
        uint256 maxTP
    ) internal pure returns (uint256) {
        require(entryPrice > 0 && leverage > 0, "Invalid position");
        require(maxTP > 0, "Invalid maxTP");

        uint256 priceDelta = (entryPrice * maxTP) / (ONE * leverage);

        if (isLong) {
            return entryPrice + priceDelta;
        }

        return priceDelta >= entryPrice ? 1 : entryPrice - priceDelta;
    }

    function _validatePairMaxTP(
        uint256 maxTP,
        uint256 maxLeverage
    ) internal pure {
        require(maxTP > 0, "Invalid maxTP");
        // The default TP must remain at least 0.1% away from entry at the
        // pair's highest leverage, matching the TP dust-distance rule.
        require(
            maxTP >= (maxLeverage * ONE) / 1000,
            "maxTP too low for max leverage"
        );
    }

    function _validateTakeProfitCap(
        PairInfo storage info,
        bool isLong,
        uint256 margin,
        uint256 size,
        uint256 entryPrice,
        uint256 takeProfit
    ) internal view {
        uint256 priceDifference = isLong
            ? takeProfit - entryPrice
            : entryPrice - takeProfit;
        uint256 takeProfitPnl = (size * priceDifference) / entryPrice;
        uint256 maxPnl = (margin * info.maxTP) / ONE;

        require(takeProfitPnl <= maxPnl, "TP exceeds pair maxTP");
    }

    // ------------------------------------------------------------------
    // OPEN POSITION
    // ------------------------------------------------------------------

    function openPosition(
        string calldata pairs,
        bool isLong,
        uint256 margin,
        uint256 leverage,
        bytes[] calldata priceUpdateData,
        uint256 takeProfit,
        uint256 stopLoss
    ) external payable whenTradingActive {
        require(margin > 0 && leverage > 0);
        PairInfo storage info = pairInfo[pairs];
        require(info.active);
        require(!pairPaused[pairs], "Pair paused");

        // Validate leverage limits for this pair
        require(leverage >= info.minLeverage, "Leverage below pair minimum");
        require(leverage <= info.maxLeverage, "Leverage exceeds pair maximum");

        // Calculate position size
        uint256 netSize = margin * leverage;
        
        // Validate position size limit
        require(netSize <= info.maxPositionSize, "Position size exceeds pair limit");

        // Validate OI limit (based on ratio distribution, split 50/50 between long and short)
        uint256 poolValue = getPoolValue();
        require(poolValue > 0, "Pool is empty");
        require(totalOIRatio > 0, "No pairs configured");
        _validateWorstCaseProfit(margin, info.maxTP);
        
        PairFunding storage pf = pairFunding[pairs];
        
        // Calculate max OI for this pair based on its ratio
        // Formula: maxOI = (poolValue * pairRatio) / totalRatio
        uint256 maxAllowedOI = (poolValue * info.oiRatio) / totalOIRatio;
        uint256 maxOIPerSide = maxAllowedOI / 2; // Split 50/50 between long and short
        
        if (isLong) {
            uint256 newLongOI = pf.oiLong + netSize;
            require(newLongOI <= maxOIPerSide, "Exceeds long OI limit");
        } else {
            uint256 newShortOI = pf.oiShort + netSize;
            require(newShortOI <= maxOIPerSide, "Exceeds short OI limit");
        }

        PythStructs.Price memory token = _updateAndGetPythPrice(
            priceUpdateData,
            info.pythTokenId
        );
        uint256 oraclePrice = toUint(token.price);

        uint256 effectiveTakeProfit = takeProfit;
        if (effectiveTakeProfit == 0) {
            effectiveTakeProfit = _calculateMaxTakeProfitPrice(
                oraclePrice,
                leverage,
                isLong,
                info.maxTP
            );
        }

        // Validate Take Profit and Stop Loss levels before opening position
        if (isLong) {
            // Long position: TP must be ABOVE entry price (profit when price goes up)
            require(effectiveTakeProfit > oraclePrice, "Long TP must be above entry price");
        } else {
            // Short position: TP must be BELOW entry price (profit when price goes down)
            require(effectiveTakeProfit < oraclePrice, "Short TP must be below entry price");
        }
        _validateTakeProfitCap(
            info,
            isLong,
            margin,
            netSize,
            oraclePrice,
            effectiveTakeProfit
        );

        if (stopLoss > 0) {
            if (isLong) {
                // Long position: SL must be BELOW entry price (loss when price goes down)
                require(stopLoss < oraclePrice, "Long SL must be below entry price");
            } else {
                // Short position: SL must be ABOVE entry price (loss when price goes up)
                require(stopLoss > oraclePrice, "Short SL must be above entry price");
            }
        }

        // Additional validation: TP and SL cannot be the same
        if (stopLoss > 0) {
            require(effectiveTakeProfit != stopLoss, "TP and SL cannot be the same price");
        }

        // Additional validation: Ensure reasonable distance from entry price (prevent dust orders)
        uint256 minDistance = oraclePrice / 1000; // 0.1% minimum distance
        if (isLong) {
            require(effectiveTakeProfit >= oraclePrice + minDistance, "TP too close to entry price");
        } else {
            require(effectiveTakeProfit <= oraclePrice - minDistance, "TP too close to entry price");
        }
        if (stopLoss > 0) {
            if (isLong) {
                require(stopLoss <= oraclePrice - minDistance, "SL too close to entry price");
            } else {
                require(stopLoss >= oraclePrice + minDistance, "SL too close to entry price");
            }
        }

        require(usdc.transferFrom(msg.sender, address(this), margin));

        // No opening fee - use full margin
        uint256 netMargin = margin;
        // netSize already calculated above

        totalOpenMargin += netMargin;

        _finalizeOpenPosition(
            pairs,
            isLong,
            netMargin,
            leverage,
            netSize,
            info.pythTokenId,
            0, // No opening fees
            oraclePrice,
            effectiveTakeProfit,
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
            Position(
                id,
                pairs,
                isLong,
                netMargin,
                leverage,
                netSize,
                entryPrice,
                pythTokenId,
                false,
                0,
                0,
                liquidationPrice,
                fees,
                pf.growth,
                tp,
                sl
            )
        );

        _reserveWorstCaseProfit(id, netMargin, pairInfo[pairs].maxTP);

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
            fees,
            tp,
            sl
        );

        // Emit validation event if TP/SL were set
        if (tp > 0 || sl > 0) {
            emit TPSLValidated(id, msg.sender, entryPrice, tp, sl, isLong, "open");
        }
    }

    // ------------------------------------------------------------------
    // MODIFY TP / SL
    // ------------------------------------------------------------------

    function modifyTpSl(
        bytes32 positionId,
        uint256 newTP,
        uint256 newSL,
        bytes[] calldata priceUpdateData
    ) external payable {
        Position[] storage userPositions = positions[msg.sender];

        for (uint256 i = 0; i < userPositions.length; i++) {
            Position storage pos = userPositions[i];

            if (pos.id == positionId && !pos.isClosed) {
                // Update the feed with frontend-supplied Pyth data, then use
                // the resulting fresh price to validate the new TP/SL levels.
                PythStructs.Price memory priceData = _updateAndGetPythPrice(
                    priceUpdateData,
                    pos.pythTokenId
                );
                require(priceData.price > 0, "Invalid oracle price");
                uint256 currentPrice = toUint(priceData.price);

                PairInfo storage info = pairInfo[pos.pairs];
                uint256 effectiveNewTP = newTP;
                if (effectiveNewTP == 0) {
                    effectiveNewTP = _calculateMaxTakeProfitPrice(
                        pos.entryPrice,
                        pos.leverage,
                        pos.isLong,
                        info.maxTP
                    );
                }

                // Validate Take Profit (TP) - must be in profit direction
                if (pos.isLong) {
                    // Long position: TP must be ABOVE current price (profit when price goes up)
                    require(effectiveNewTP > currentPrice, "Long TP must be above current price");
                } else {
                    // Short position: TP must be BELOW current price (profit when price goes down)
                    require(effectiveNewTP < currentPrice, "Short TP must be below current price");
                }
                _validateTakeProfitCap(
                    info,
                    pos.isLong,
                    pos.margin,
                    pos.size,
                    pos.entryPrice,
                    effectiveNewTP
                );

                // Validate Stop Loss (SL) - must be in loss direction
                if (newSL > 0) {
                    if (pos.isLong) {
                        // Long position: SL must be BELOW current price (loss when price goes down)
                        require(newSL < currentPrice, "Long SL must be below current price");
                    } else {
                        // Short position: SL must be ABOVE current price (loss when price goes up)
                        require(newSL > currentPrice, "Short SL must be above current price");
                    }
                }

                // Additional validation: TP and SL cannot be the same
                if (newSL > 0) {
                    require(effectiveNewTP != newSL, "TP and SL cannot be the same price");
                }

                // Additional validation: Ensure reasonable distance from current price (prevent dust orders)
                uint256 minDistance = currentPrice / 1000; // 0.1% minimum distance
                if (pos.isLong) {
                    require(effectiveNewTP >= currentPrice + minDistance, "TP too close to current price");
                } else {
                    require(effectiveNewTP <= currentPrice - minDistance, "TP too close to current price");
                }
                if (newSL > 0) {
                    if (pos.isLong) {
                        require(newSL <= currentPrice - minDistance, "SL too close to current price");
                    } else {
                        require(newSL >= currentPrice + minDistance, "SL too close to current price");
                    }
                }

                // Update the TP/SL values
                pos.takeProfit = effectiveNewTP;
                pos.stopLoss = newSL;

                emit TPSLModified(positionId, msg.sender, effectiveNewTP, newSL);
                emit TPSLValidated(positionId, msg.sender, currentPrice, effectiveNewTP, newSL, pos.isLong, "modify");
                return;
            }
        }

        revert("Position not found");
    }

    // ------------------------------------------------------------------
    // CLOSE POSITION (manual close)
    // ------------------------------------------------------------------

    function closePosition(
        bytes32 positionId,
        bytes[] calldata priceUpdateData
    ) external payable {
        Position[] storage userPositions = positions[msg.sender];

        for (uint256 i = 0; i < userPositions.length; i++) {
            Position storage pos = userPositions[i];

            if (!pos.isClosed && pos.id == positionId) {
                require(!pairPaused[pos.pairs], "Pair paused");
                PythStructs.Price memory token = _updateAndGetPythPrice(
                    priceUpdateData,
                    pos.pythTokenId
                );
                uint256 currentPrice = toUint(token.price);

                _closePosition(msg.sender, pos, currentPrice, "close");
                return;
            }
        }
        revert("Position not found");
    }

    // ------------------------------------------------------------------
    // TP/SL BOT
    // ------------------------------------------------------------------

    function triggerTpSl(
        address user,
        bytes32 positionId,
        bytes[] calldata priceUpdateData
    ) external payable {
        Position[] storage userPositions = positions[user];

        for (uint256 i = 0; i < userPositions.length; i++) {
            Position storage pos = userPositions[i];

            if (!pos.isClosed && pos.id == positionId) {
                require(!pairPaused[pos.pairs], "Pair paused");
                PythStructs.Price memory token = _updateAndGetPythPrice(
                    priceUpdateData,
                    pos.pythTokenId
                );
                uint256 currentPrice = toUint(token.price);

                // SAFETY CHECK: Ensure position is not liquidatable before processing TP/SL
                // Calculate current equity to prevent liquidation through TP/SL
                int256 pnl = pos.isLong
                    ? (int256(pos.size) * (int256(currentPrice) - int256(pos.entryPrice))) / int256(pos.entryPrice)
                    : (int256(pos.size) * (int256(pos.entryPrice) - int256(currentPrice))) / int256(pos.entryPrice);

                PairFunding storage pf = pairFunding[pos.pairs];
                int256 fundingPayment = (int256(pos.size) * (pf.growth - pos.fundingEntry)) / int256(ONE);
                int256 equity = int256(pos.margin) + pnl - fundingPayment;

                // If position is liquidatable (equity <= 0), reject TP/SL trigger
                require(equity > 0, "Position is liquidatable, use liquidate() function");

                bool hitTP = false;
                bool hitSL = false;
                string memory status = "";
                uint256 closePrice = currentPrice; // Default to current price

                // Check Take Profit conditions
                if (pos.takeProfit > 0) {
                    if (pos.isLong && currentPrice >= pos.takeProfit) {
                        hitTP = true;
                        status = "tp";
                        closePrice = pos.takeProfit; // Use exact TP price
                    }
                    if (!pos.isLong && currentPrice <= pos.takeProfit) {
                        hitTP = true;
                        status = "tp";
                        closePrice = pos.takeProfit; // Use exact TP price
                    }
                }

                // Check Stop Loss conditions
                if (pos.stopLoss > 0) {
                    if (pos.isLong && currentPrice <= pos.stopLoss) {
                        hitSL = true;
                        status = "sl";
                        closePrice = pos.stopLoss; // Use exact SL price
                    }
                    if (!pos.isLong && currentPrice >= pos.stopLoss) {
                        hitSL = true;
                        status = "sl";
                        closePrice = pos.stopLoss; // Use exact SL price
                    }
                }

                require(hitTP || hitSL, "No TP/SL triggered");

                // ADDITIONAL SAFETY: Double-check equity at close price won't cause liquidation
                int256 closePnl = pos.isLong
                    ? (int256(pos.size) * (int256(closePrice) - int256(pos.entryPrice))) / int256(pos.entryPrice)
                    : (int256(pos.size) * (int256(pos.entryPrice) - int256(closePrice))) / int256(pos.entryPrice);
                
                int256 closeEquity = int256(pos.margin) + closePnl - fundingPayment;
                require(closeEquity > 0, "TP/SL would result in liquidation, use liquidate() function");

                // Close at exact TP/SL price, not current market price
                _closePosition(user, pos, closePrice, status);
                return;
            }
        }

        revert("Position not found");
    }

    // ------------------------------------------------------------------
    // LIQUIDATION
    // ------------------------------------------------------------------

    function liquidate(
        address user,
        bytes32 positionId,
        bytes[] calldata priceUpdateData
    ) external payable {
        Position[] storage userPositions = positions[user];

        for (uint256 i = 0; i < userPositions.length; i++) {
            Position storage pos = userPositions[i];

            if (!pos.isClosed && pos.id == positionId) {
                PythStructs.Price memory token = _updateAndGetPythPrice(
                    priceUpdateData,
                    pos.pythTokenId
                );
                uint256 price = toUint(token.price);

                // PROTECTION: Check if Stop Loss should be triggered instead of liquidation
                if (pos.stopLoss > 0) {
                    bool shouldTriggerSL = false;
                    
                    if (pos.isLong && price <= pos.stopLoss) {
                        shouldTriggerSL = true;
                    }
                    if (!pos.isLong && price >= pos.stopLoss) {
                        shouldTriggerSL = true;
                    }
                    
                    // If SL should be triggered, execute SL instead of liquidation
                    if (shouldTriggerSL) {
                        // Calculate equity at SL price to ensure it's better than liquidation
                        int256 slPnl = pos.isLong
                            ? (int256(pos.size) * (int256(pos.stopLoss) - int256(pos.entryPrice))) / int256(pos.entryPrice)
                            : (int256(pos.size) * (int256(pos.entryPrice) - int256(pos.stopLoss))) / int256(pos.entryPrice);
                        
                        PairFunding storage pfSL = pairFunding[pos.pairs];
                        int256 fundingPaymentSL = (int256(pos.size) * (pfSL.growth - pos.fundingEntry)) / int256(ONE);
                        int256 slEquity = int256(pos.margin) + slPnl - fundingPaymentSL;
                        
                        // If SL gives better outcome than liquidation (equity > 0), execute SL
                        if (slEquity > 0) {
                            emit SLExecutedByLiquidationBot(
                                pos.id,
                                user,
                                msg.sender,
                                pos.stopLoss,
                                uint256(slEquity > int256(pos.margin) ? slEquity : int256(pos.margin)),
                                "TP/SL bot out of gas, liquidation bot executed SL"
                            );
                            _closePosition(user, pos, pos.stopLoss, "sl");
                            return;
                        }
                        // If SL would also result in liquidation, continue with normal liquidation
                    }
                }

                // Normal liquidation logic
                require(!pairPaused[pos.pairs], "Pair paused");
                int256 pnl = pos.isLong
                    ? (int256(pos.size) * (int256(price) - int256(pos.entryPrice))) / int256(pos.entryPrice)
                    : (int256(pos.size) * (int256(pos.entryPrice) - int256(price))) / int256(pos.entryPrice);

                PairFunding storage pf = pairFunding[pos.pairs];
                int256 fundingPayment = (int256(pos.size) * (pf.growth - pos.fundingEntry)) / int256(ONE);
                int256 equity = int256(pos.margin) + pnl - fundingPayment;

                // Liquidation: max loss is 100% of margin (equity <= 0)
                require(equity <= 0, "Not liquidatable");

                if (pos.isLong) {
                    pf.oiLong = pf.oiLong >= pos.size
                        ? pf.oiLong - pos.size
                        : 0;
                } else {
                    pf.oiShort = pf.oiShort >= pos.size
                        ? pf.oiShort - pos.size
                        : 0;
                }

                if (totalOpenMargin >= pos.margin)
                    totalOpenMargin -= pos.margin;
                else totalOpenMargin = 0;

                // Track vault PnL - vault gains the full margin on liquidation
                int256 vaultPnL = int256(pos.margin); // Vault gains 100% of margin
                vaultTotalPnL += vaultPnL;
                vaultTotalProfit += pos.margin;

                pos.isClosed = true;
                pos.closePrice = price;
                pos.payout = 0; // User gets nothing on liquidation

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
        _accrueFunding(pos.pairs);

        int256 pnl = pos.isLong
            ? (int256(pos.size) * (int256(price) - int256(pos.entryPrice))) /
                int256(pos.entryPrice)
            : (int256(pos.size) * (int256(pos.entryPrice) - int256(price))) /
                int256(pos.entryPrice);

        PairFunding storage pf = pairFunding[pos.pairs];
        int256 fundingPayment = (int256(pos.size) *
            (pf.growth - pos.fundingEntry)) / int256(ONE);

        int256 cappedPnl = pnl;
        if (cappedPnl > 0) {
            // Use the liability reserved at open, not the mutable pair
            // configuration, so later maxTP changes cannot increase LP risk.
            int256 maxPnl = int256(positionWorstCaseProfit[pos.id]);
            if (cappedPnl > maxPnl) cappedPnl = maxPnl;
        }

        int256 rawPayout = int256(pos.margin) + cappedPnl - fundingPayment;
        uint256 payout = rawPayout > 0 ? uint256(rawPayout) : 0;

        // Calculate vault PnL (opposite of user PnL)
        // User profit = Vault loss, User loss = Vault profit
        int256 userPnL = int256(payout) - int256(pos.margin);
        int256 vaultPnL = -userPnL; // Vault PnL is opposite of user PnL

        // Track realized vault PnL
        vaultTotalPnL += vaultPnL;
        if (vaultPnL > 0) {
            // Vault gained (user lost)
            vaultTotalProfit += uint256(vaultPnL);
        } else if (vaultPnL < 0) {
            // Vault lost (user won)
            vaultTotalLoss += uint256(-vaultPnL);
        }

        // Apply 2% fee ONLY on winning positions (when payout > margin)
        uint256 closeFee = 0;
        if (payout > pos.margin) {
            // Position is profitable - calculate fee on profit only
            uint256 profit = payout - pos.margin;
            closeFee = (profit * WINNING_FEE_BPS) / 10000;
            payout = payout - closeFee;

            // Collect fee to secondary vault
            _collectFeeToSecondaryVault(closeFee, pos.id, user);
        }
        // If payout <= margin, it's a loss - no fee applied

        if (pos.isLong) {
            pf.oiLong = pf.oiLong >= pos.size ? pf.oiLong - pos.size : 0;
        } else {
            pf.oiShort = pf.oiShort >= pos.size ? pf.oiShort - pos.size : 0;
        }

        if (totalOpenMargin >= pos.margin) totalOpenMargin -= pos.margin;
        else totalOpenMargin = 0;

        if (payout > 0) require(usdc.transfer(user, payout));

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

    function closeAllPositions() external onlyOwner {
        for (uint256 u = 0; u < allUsers.length; u++) {
            address user = allUsers[u];
            Position[] storage userPositions = positions[user];

            for (uint256 i = 0; i < userPositions.length; i++) {
                Position storage pos = userPositions[i];

                if (!pos.isClosed && !pairPaused[pos.pairs]) {
                    PythStructs.Price memory token = pyth.getPrice(
                        pos.pythTokenId
                    );
                    if (token.price <= 0) continue;

                    uint256 price = toUint(token.price);
                    _closePosition(user, pos, price, "close");
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
     * @param oiRatio OI ratio weight (e.g., 10 for BTC, 5 for ETH)
     * @param maxPositionSize Max position size in USDC (e.g., 5000e6 = 5000 USDC)
     * @param minLeverage Minimum leverage allowed (e.g., 2 = 2x)
     * @param maxLeverage Maximum leverage allowed (e.g., 100 = 100x)
     */
    function updatePairConfig(
        string calldata pairs,
        uint256 oiRatio,
        uint256 maxPositionSize,
        uint256 minLeverage,
        uint256 maxLeverage
    ) external onlyOwner {
        PairInfo storage info = pairInfo[pairs];
        require(bytes(info.name).length > 0, "Pair does not exist");
        require(minLeverage > 0 && maxLeverage > 0, "Invalid leverage");
        require(minLeverage <= maxLeverage, "Min leverage > max leverage");
        require(oiRatio > 0, "Invalid OI ratio");
        require(maxPositionSize > 0, "Invalid position size");
        _validatePairMaxTP(info.maxTP, maxLeverage);

        // Update total ratio
        totalOIRatio = totalOIRatio - info.oiRatio + oiRatio;
        
        info.oiRatio = oiRatio;
        info.maxPositionSize = maxPositionSize;
        info.minLeverage = minLeverage;
        info.maxLeverage = maxLeverage;

        emit PairConfigUpdated(pairs, oiRatio, maxPositionSize, minLeverage, maxLeverage);
    }

    /**
     * @notice Update the maximum gross profit for a pair.
     * @param pairs Trading pair name
     * @param maxTP Maximum profit as an 18-decimal ratio of margin
     *              (1e18 = 100%, 5e18 = 500%)
     */
    function updatePairMaxTP(
        string calldata pairs,
        uint256 maxTP
    ) external onlyOwner {
        PairInfo storage info = pairInfo[pairs];
        require(bytes(info.name).length > 0, "Pair does not exist");
        _validatePairMaxTP(maxTP, info.maxLeverage);

        info.maxTP = maxTP;

        // Keep the enumerable pair copy consistent with the mapping.
        for (uint256 i = 0; i < allPairs.length; i++) {
            if (
                keccak256(bytes(allPairs[i].name)) ==
                keccak256(bytes(pairs))
            ) {
                allPairs[i].maxTP = maxTP;
                break;
            }
        }

        emit PairMaxTPUpdated(pairs, maxTP);
    }

    /**
     * @notice Update pair active status (owner only)
     * @param pairs Trading pair name
     * @param active True to activate, false to deactivate
     */
    function setPairActive(string calldata pairs, bool active) external onlyOwner {
        PairInfo storage info = pairInfo[pairs];
        require(bytes(info.name).length > 0, "Pair does not exist");
        
        info.active = active;
        emit PairStatus(pairs, active);
    }

    /// @notice Freezes every trading action for one pair except TP/SL edits.
    function setPairPaused(string calldata pairs, bool paused) external onlyOwner {
        require(bytes(pairInfo[pairs].name).length > 0, "Pair does not exist");
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
     * @param pythTokenId Pyth price feed ID
     * @param oiRatio OI ratio weight
     * @param maxPositionSize Max position size in USDC
     * @param minLeverage Minimum leverage
     * @param maxLeverage Maximum leverage
     * @param maxTP Maximum profit ratio (1e18 = 100% of margin)
     */
    function addPair(
        string calldata pairs,
        bytes32 pythTokenId,
        uint256 oiRatio,
        uint256 maxPositionSize,
        uint256 minLeverage,
        uint256 maxLeverage,
        uint256 maxTP
    ) external onlyOwner {
        require(bytes(pairInfo[pairs].name).length == 0, "Pair already exists");
        require(minLeverage > 0 && maxLeverage > 0, "Invalid leverage");
        require(minLeverage <= maxLeverage, "Min leverage > max leverage");
        require(oiRatio > 0, "Invalid OI ratio");
        require(maxPositionSize > 0, "Invalid position size");

        _addPair(
            pairs,
            pythTokenId,
            oiRatio,
            maxPositionSize,
            minLeverage,
            maxLeverage,
            maxTP
        );
    }

    event PairConfigUpdated(
        string pairs,
        uint256 maxOIPercentage,
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

    function toUint(int64 x) internal pure returns (uint256) {
        require(x >= 0);
        return uint256(int256(x));
    }

    // Helper function to check if a position is liquidatable
    function isPositionLiquidatable(
        Position storage pos,
        uint256 currentPrice
    ) internal view returns (bool, int256) {
        int256 pnl = pos.isLong
            ? (int256(pos.size) * (int256(currentPrice) - int256(pos.entryPrice))) / int256(pos.entryPrice)
            : (int256(pos.size) * (int256(pos.entryPrice) - int256(currentPrice))) / int256(pos.entryPrice);

        PairFunding storage pf = pairFunding[pos.pairs];
        int256 fundingPayment = (int256(pos.size) * (pf.growth - pos.fundingEntry)) / int256(ONE);
        int256 equity = int256(pos.margin) + pnl - fundingPayment;

        return (equity <= 0, equity);
    }

    // Public function to check position health (for frontend/bots)
    function getPositionEquity(
        address user,
        bytes32 positionId,
        uint256 currentPrice
    ) external view returns (int256 equity, bool isLiquidatable) {
        Position[] storage userPositions = positions[user];
        
        for (uint256 i = 0; i < userPositions.length; i++) {
            Position storage pos = userPositions[i];
            if (pos.id == positionId && !pos.isClosed) {
                (isLiquidatable, equity) = isPositionLiquidatable(pos, currentPrice);
                return (equity, isLiquidatable);
            }
        }
        
        revert("Position not found");
    }

    function getppUSDCAddress() external view returns (address) {
        return address(ppUSDC);
    }

    function getUSDCAddress() external view returns (address) {
        return address(usdc);
    }

    /**
     * @notice Get available OI for a trading pair
     * @param pairs Trading pair name (e.g., "BTC_USD")
     * @return maxOIPerSide Maximum OI allowed per side (long or short)
     * @return currentLongOI Current long OI
     * @return currentShortOI Current short OI
     * @return availableLongOI Available OI for long positions
     * @return availableShortOI Available OI for short positions
     * @return maxPositionSize Maximum position size allowed
     */
    function getAvailableOI(string calldata pairs)
        external
        view
        returns (
            uint256 maxOIPerSide,
            uint256 currentLongOI,
            uint256 currentShortOI,
            uint256 availableLongOI,
            uint256 availableShortOI,
            uint256 maxPositionSize
        )
    {
        PairInfo storage info = pairInfo[pairs];
        PairFunding storage pf = pairFunding[pairs];
        
        uint256 poolValue = getPoolValue();
        
        if (totalOIRatio > 0) {
            // Calculate max OI based on ratio: (poolValue * pairRatio) / totalRatio
            uint256 maxAllowedOI = (poolValue * info.oiRatio) / totalOIRatio;
            maxOIPerSide = maxAllowedOI / 2; // Split 50/50 between long and short
        } else {
            maxOIPerSide = 0;
        }
        
        currentLongOI = pf.oiLong;
        currentShortOI = pf.oiShort;
        
        availableLongOI = maxOIPerSide > currentLongOI ? maxOIPerSide - currentLongOI : 0;
        availableShortOI = maxOIPerSide > currentShortOI ? maxOIPerSide - currentShortOI : 0;
        
        maxPositionSize = info.maxPositionSize;
    }

}

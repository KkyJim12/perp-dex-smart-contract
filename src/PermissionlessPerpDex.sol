// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

interface IppUSDC {
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

/**
 * @title PermissionlessPerpDex
 * @dev Permissionless perpetual trading contract that shares LP pool with main PerpDex
 * - Users deposit funds to contract
 * - Backend handles price feeds and trade execution
 * - Contract only handles fund movements based on win/loss
 * - No oracle integration - backend provides all price data
 * - Uses same ppUSDC LP pool as main PerpDex for liquidity
 */
contract PermissionlessPerpDex is Ownable, ReentrancyGuard {
    ERC20 public immutable usdc;
    IppUSDC public immutable ppUSDC; // Shared LP token with main PerpDex
    
    // Trading parameters
    uint256 public constant WINNING_FEE_BPS = 200; // 2% fee on winning positions only
    uint256 public constant MAX_LEVERAGE = 100; // 100x max leverage
    uint256 public constant MIN_MARGIN = 1e6; // 1 USDC minimum margin
    uint256 public constant ONE = 1e18;
    
    // User balances
    mapping(address => uint256) public userBalances;
    mapping(address => uint256) public lockedBalances; // Funds locked in open positions
    
    // Position tracking
    struct Position {
        bytes32 id;
        address user;
        string pair;
        bool isLong;
        uint256 margin;
        uint256 leverage;
        uint256 size;
        uint256 entryPrice; // Price with 8 decimals (like Pyth)
        uint256 timestamp;
        bool isActive;
    }
    
    mapping(bytes32 => Position) public positions;
    mapping(address => bytes32[]) public userPositions;
    bytes32[] public allPositions;
    
    // Statistics
    uint256 public totalDeposits;
    uint256 public totalWithdrawals;
    uint256 public totalLockedFunds;
    uint256 public totalFeesCollected;
    
    // Pool integration - track trader margins separately from LP pool
    uint256 public totalTraderMargin; // Total margin from traders (not part of LP pool)
    
    // Pool PnL tracking (shared with main PerpDex)
    int256 public poolTotalPnL; // Cumulative pool profit/loss from this contract
    uint256 public poolTotalProfit; // Total profit earned by pool
    uint256 public poolTotalLoss; // Total loss taken by pool
    
    // Backend management
    mapping(address => bool) public authorizedBackends;
    
    // Events
    event Deposit(address indexed user, uint256 amount, uint256 newBalance);
    event Withdraw(address indexed user, uint256 amount, uint256 newBalance);
    event PositionOpened(
        bytes32 indexed positionId,
        address indexed user,
        string pair,
        bool isLong,
        uint256 margin,
        uint256 leverage,
        uint256 size,
        uint256 entryPrice
    );
    event PositionClosed(
        bytes32 indexed positionId,
        address indexed user,
        uint256 exitPrice,
        int256 pnl,
        uint256 payout,
        uint256 fee,
        string reason
    );
    event BackendAuthorized(address indexed backend, bool authorized);
    event FeeCollected(uint256 amount);
    event PoolPnLUpdated(int256 pnl, uint256 totalProfit, uint256 totalLoss);
    event LPDeposit(address indexed user, uint256 amount, uint256 shares);
    event LPWithdraw(address indexed user, uint256 amount, uint256 shares);
    
    modifier onlyAuthorizedBackend() {
        require(authorizedBackends[msg.sender], "Not authorized backend");
        _;
    }
    
    constructor(address _usdc, address _ppUSDC) Ownable(msg.sender) {
        require(_usdc != address(0), "Invalid USDC address");
        require(_ppUSDC != address(0), "Invalid ppUSDC address");
        usdc = ERC20(_usdc);
        ppUSDC = IppUSDC(_ppUSDC);
    }
    
    // ------------------------------------------------------------------
    // POOL INTEGRATION
    // ------------------------------------------------------------------
    
    function getPoolValue() public view returns (uint256) {
        uint256 contractBalance = usdc.balanceOf(address(this));
        
        // Subtract trader margins (these belong to traders, not the pool)
        uint256 reserved = totalTraderMargin + totalFeesCollected;
        
        if (contractBalance <= reserved) {
            return 0; // Pool is empty
        }
        
        return contractBalance - reserved;
    }
    
    function getPoolStats() external view returns (
        int256 totalPnL,
        uint256 totalProfit,
        uint256 totalLoss,
        uint256 poolValue
    ) {
        totalPnL = poolTotalPnL;
        totalProfit = poolTotalProfit;
        totalLoss = poolTotalLoss;
        poolValue = getPoolValue();
    }
    
    // ------------------------------------------------------------------
    // BACKEND MANAGEMENT
    // ------------------------------------------------------------------
    
    function authorizeBackend(address backend, bool authorized) external onlyOwner {
        authorizedBackends[backend] = authorized;
        emit BackendAuthorized(backend, authorized);
    }
    
    // ------------------------------------------------------------------
    // USER FUND MANAGEMENT
    // ------------------------------------------------------------------
    
    function deposit(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be > 0");
        
        require(usdc.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        
        userBalances[msg.sender] += amount;
        totalDeposits += amount;
        
        emit Deposit(msg.sender, amount, userBalances[msg.sender]);
    }
    
    function withdraw(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be > 0");
        
        uint256 availableBalance = getAvailableBalance(msg.sender);
        require(availableBalance >= amount, "Insufficient available balance");
        
        userBalances[msg.sender] -= amount;
        totalWithdrawals += amount;
        
        require(usdc.transfer(msg.sender, amount), "Transfer failed");
        
        emit Withdraw(msg.sender, amount, userBalances[msg.sender]);
    }
    
    function getAvailableBalance(address user) public view returns (uint256) {
        uint256 totalBalance = userBalances[user];
        uint256 locked = lockedBalances[user];
        return totalBalance > locked ? totalBalance - locked : 0;
    }
    
    function getUserInfo(address user) external view returns (
        uint256 totalBalance,
        uint256 lockedBalance,
        uint256 availableBalance,
        uint256 activePositions
    ) {
        totalBalance = userBalances[user];
        lockedBalance = lockedBalances[user];
        availableBalance = getAvailableBalance(user);
        activePositions = getUserActivePositionsCount(user);
    }
    
    // ------------------------------------------------------------------
    // POSITION MANAGEMENT (BACKEND ONLY)
    // ------------------------------------------------------------------
    
    function openPosition(
        address user,
        string calldata pair,
        bool isLong,
        uint256 margin,
        uint256 leverage,
        uint256 entryPrice
    ) external onlyAuthorizedBackend nonReentrant returns (bytes32 positionId) {
        require(margin >= MIN_MARGIN, "Margin too small");
        require(leverage > 0 && leverage <= MAX_LEVERAGE, "Invalid leverage");
        require(entryPrice > 0, "Invalid entry price");
        
        uint256 availableBalance = getAvailableBalance(user);
        require(availableBalance >= margin, "Insufficient balance");
        
        // Generate position ID
        positionId = keccak256(abi.encodePacked(
            user,
            pair,
            block.timestamp,
            block.number,
            allPositions.length
        ));
        
        uint256 size = margin * leverage;
        
        // Lock user funds
        lockedBalances[user] += margin;
        totalLockedFunds += margin;
        totalTraderMargin += margin; // Track separately from pool
        
        // Create position
        positions[positionId] = Position({
            id: positionId,
            user: user,
            pair: pair,
            isLong: isLong,
            margin: margin,
            leverage: leverage,
            size: size,
            entryPrice: entryPrice,
            timestamp: block.timestamp,
            isActive: true
        });
        
        userPositions[user].push(positionId);
        allPositions.push(positionId);
        
        emit PositionOpened(positionId, user, pair, isLong, margin, leverage, size, entryPrice);
    }
    
    function closePosition(
        bytes32 positionId,
        uint256 exitPrice,
        string calldata reason
    ) external onlyAuthorizedBackend nonReentrant {
        Position storage pos = positions[positionId];
        require(pos.isActive, "Position not active");
        require(exitPrice > 0, "Invalid exit price");
        
        // Calculate PnL
        int256 pnl = calculatePnL(pos, exitPrice);
        
        // Calculate payout
        int256 rawPayout = int256(pos.margin) + pnl;
        uint256 payout = rawPayout > 0 ? uint256(rawPayout) : 0;
        
        // Calculate fee (only on winning positions)
        uint256 fee = 0;
        if (pnl > 0) {
            fee = (uint256(pnl) * WINNING_FEE_BPS) / 10000;
            payout = payout > fee ? payout - fee : 0;
            totalFeesCollected += fee;
            emit FeeCollected(fee);
        }
        
        // Track pool PnL (opposite of trader PnL)
        // Trader profit = Pool loss, Trader loss = Pool profit
        int256 traderPnL = int256(payout) - int256(pos.margin);
        int256 poolPnL = -traderPnL; // Pool PnL is opposite of trader PnL
        
        // Update pool PnL tracking
        poolTotalPnL += poolPnL;
        if (poolPnL > 0) {
            // Pool gained (trader lost)
            poolTotalProfit += uint256(poolPnL);
        } else if (poolPnL < 0) {
            // Pool lost (trader won)
            poolTotalLoss += uint256(-poolPnL);
        }
        
        emit PoolPnLUpdated(poolTotalPnL, poolTotalProfit, poolTotalLoss);
        
        // Unlock user funds
        lockedBalances[pos.user] = lockedBalances[pos.user] >= pos.margin 
            ? lockedBalances[pos.user] - pos.margin 
            : 0;
        totalLockedFunds = totalLockedFunds >= pos.margin 
            ? totalLockedFunds - pos.margin 
            : 0;
        totalTraderMargin = totalTraderMargin >= pos.margin
            ? totalTraderMargin - pos.margin
            : 0;
        
        // Update user balance with payout
        if (payout > 0) {
            userBalances[pos.user] += payout;
        }
        
        // Mark position as closed
        pos.isActive = false;
        
        emit PositionClosed(positionId, pos.user, exitPrice, pnl, payout, fee, reason);
    }
    
    function liquidatePosition(
        bytes32 positionId,
        uint256 liquidationPrice
    ) external onlyAuthorizedBackend nonReentrant {
        Position storage pos = positions[positionId];
        require(pos.isActive, "Position not active");
        require(liquidationPrice > 0, "Invalid liquidation price");
        
        // On liquidation, user loses entire margin
        lockedBalances[pos.user] = lockedBalances[pos.user] >= pos.margin 
            ? lockedBalances[pos.user] - pos.margin 
            : 0;
        totalLockedFunds = totalLockedFunds >= pos.margin 
            ? totalLockedFunds - pos.margin 
            : 0;
        totalTraderMargin = totalTraderMargin >= pos.margin
            ? totalTraderMargin - pos.margin
            : 0;
        
        // Track pool PnL - pool gains the full margin on liquidation
        int256 poolPnL = int256(pos.margin);
        poolTotalPnL += poolPnL;
        poolTotalProfit += pos.margin;
        
        emit PoolPnLUpdated(poolTotalPnL, poolTotalProfit, poolTotalLoss);
        
        // User gets nothing on liquidation
        pos.isActive = false;
        
        emit PositionClosed(positionId, pos.user, liquidationPrice, -int256(pos.margin), 0, 0, "liquidated");
    }
    
    // ------------------------------------------------------------------
    // VIEW FUNCTIONS
    // ------------------------------------------------------------------
    
    function calculatePnL(Position memory pos, uint256 exitPrice) public pure returns (int256) {
        if (pos.isLong) {
            // Long: profit when price goes up
            return (int256(pos.size) * (int256(exitPrice) - int256(pos.entryPrice))) / int256(pos.entryPrice);
        } else {
            // Short: profit when price goes down
            return (int256(pos.size) * (int256(pos.entryPrice) - int256(exitPrice))) / int256(pos.entryPrice);
        }
    }
    
    function getPosition(bytes32 positionId) external view returns (Position memory) {
        return positions[positionId];
    }
    
    function getUserPositions(address user) external view returns (bytes32[] memory) {
        return userPositions[user];
    }
    
    function getUserActivePositions(address user) external view returns (bytes32[] memory activeIds) {
        bytes32[] memory userIds = userPositions[user];
        uint256 activeCount = 0;
        
        // Count active positions
        for (uint256 i = 0; i < userIds.length; i++) {
            if (positions[userIds[i]].isActive) {
                activeCount++;
            }
        }
        
        // Create array of active position IDs
        activeIds = new bytes32[](activeCount);
        uint256 index = 0;
        for (uint256 i = 0; i < userIds.length; i++) {
            if (positions[userIds[i]].isActive) {
                activeIds[index] = userIds[i];
                index++;
            }
        }
    }
    
    function getUserActivePositionsCount(address user) public view returns (uint256 count) {
        bytes32[] memory userIds = userPositions[user];
        for (uint256 i = 0; i < userIds.length; i++) {
            if (positions[userIds[i]].isActive) {
                count++;
            }
        }
    }
    
    function getContractStats() external view returns (
        uint256 totalUsers,
        uint256 totalPositionsCount,
        uint256 activePositionsCount,
        uint256 contractBalance,
        uint256 _totalDeposits,
        uint256 _totalWithdrawals,
        uint256 _totalLockedFunds,
        uint256 _totalFeesCollected
    ) {
        contractBalance = usdc.balanceOf(address(this));
        _totalDeposits = totalDeposits;
        _totalWithdrawals = totalWithdrawals;
        _totalLockedFunds = totalLockedFunds;
        _totalFeesCollected = totalFeesCollected;
        
        totalPositionsCount = allPositions.length;
        
        // Count active positions
        for (uint256 i = 0; i < allPositions.length; i++) {
            if (positions[allPositions[i]].isActive) {
                activePositionsCount++;
            }
        }
        
        // Note: totalUsers would require additional tracking
        totalUsers = 0; // Would need separate implementation
    }
    
    // ------------------------------------------------------------------
    // LP POOL FUNCTIONS (Shared with main PerpDex)
    // ------------------------------------------------------------------
    
    function depositLP(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be > 0");
        
        uint256 totalSupply = ppUSDC.totalSupply();
        uint256 currentTVL = getPoolValue();
        
        uint256 ppUSDCToMint;
        
        if (totalSupply == 0) {
            // First deposit: 1:1 ratio (1 USDC = 1 ppUSDC)
            ppUSDCToMint = amount;
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

        emit LPDeposit(msg.sender, amount, ppUSDCToMint);
    }

    function withdrawLP(uint256 ppUSDCAmount) external nonReentrant {
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
        
        // Safety check: ensure contract has enough USDC
        uint256 contractBalance = usdc.balanceOf(address(this));
        require(contractBalance >= usdcAmount, "Insufficient contract balance");

        // Burn ppUSDC from user
        ppUSDC.burn(msg.sender, ppUSDCAmount);

        // Transfer USDC to user
        require(usdc.transfer(msg.sender, usdcAmount), "Transfer failed");

        emit LPWithdraw(msg.sender, usdcAmount, ppUSDCAmount);
    }
    
    function getppUSDCPrice() external view returns (uint256) {
        uint256 totalSupply = ppUSDC.totalSupply();
        if (totalSupply == 0) return ONE; // 1:1 ratio for first deposit
        
        uint256 poolValue = getPoolValue();
        if (poolValue == 0) return 0; // Pool is empty
        
        return (poolValue * ONE) / totalSupply;
    }
    
    // ------------------------------------------------------------------
    // EMERGENCY FUNCTIONS
    // ------------------------------------------------------------------
    
    function emergencyWithdrawFees() external onlyOwner {
        uint256 contractBalance = usdc.balanceOf(address(this));
        uint256 userFunds = totalDeposits - totalWithdrawals;
        
        if (contractBalance > userFunds) {
            uint256 fees = contractBalance - userFunds;
            require(usdc.transfer(owner(), fees), "Transfer failed");
        }
    }
    
    function emergencyClosePosition(bytes32 positionId) external onlyOwner {
        Position storage pos = positions[positionId];
        require(pos.isActive, "Position not active");
        
        // Return margin to user
        lockedBalances[pos.user] = lockedBalances[pos.user] >= pos.margin 
            ? lockedBalances[pos.user] - pos.margin 
            : 0;
        totalLockedFunds = totalLockedFunds >= pos.margin 
            ? totalLockedFunds - pos.margin 
            : 0;
        totalTraderMargin = totalTraderMargin >= pos.margin
            ? totalTraderMargin - pos.margin
            : 0;
        
        userBalances[pos.user] += pos.margin;
        pos.isActive = false;
        
        emit PositionClosed(positionId, pos.user, pos.entryPrice, 0, pos.margin, 0, "emergency_close");
    }
}
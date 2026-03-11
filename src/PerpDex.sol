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
}

contract PerpDEX {
    IPyth public immutable pyth;
    ERC20 public immutable usdc;
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

    uint256 public constant MAX_PNL_RATIO = 5e18; // 500%

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
    }

    mapping(address => Position[]) public positions;
    mapping(address => string) public username;
    mapping(string => address) public usernameTaken;
    mapping(string => PairFunding) public pairFunding;
    mapping(string => PairInfo) public pairInfo;

    PairInfo[] public allPairs;
    address[] public allUsers;

    uint256 public totalOpenMargin;
    uint256 public totalOIRatio; // Sum of all pair OI ratios

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

    constructor(address _usdc, address _pyth, address _ppUSDC) {
        require(
            _usdc != address(0) && _pyth != address(0) && _ppUSDC != address(0),
            "Invalid address"
        );
        usdc = ERC20(_usdc);
        pyth = IPyth(_pyth);
        ppUSDC = IppUSDC(_ppUSDC);
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
        _addInitialPairs();
    }

    receive() external payable {}

    function _addInitialPairs() internal {
        // Cryptocurrencies with OI ratios, position size limits, and leverage limits
        // Based on database seeder configuration
        // oiRatio: weight for OI distribution (higher = more OI allocation)
        // maxPositionSize in USDC (with 6 decimals)
        // minLeverage and maxLeverage (e.g., 2 = 2x, 100 = 100x)
        // maxOIPercentage from seeder (e.g., 2000 = 20%, 1000 = 10%)
        
        // 100x Leverage Pairs - Crypto
        addPairInternal(
            "BTC_USD",
            0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43,
            20,        // maxOIPercentage: 2000 (20%)
            50000e6,   // 50000 USDC max
            2,         // Min 2x
            100        // Max 100x
        );
        addPairInternal(
            "ETH_USD",
            0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace,
            10,        // maxOIPercentage: 1000 (10%)
            50000e6,   // 50000 USDC max
            2,
            100
        );
        addPairInternal(
            "SOL_USD",
            0xef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d,
            10,        // maxOIPercentage: 1000 (10%)
            50000e6,   // 50000 USDC max
            2,
            100
        );
        
        // 75x Leverage Pairs - Crypto
        addPairInternal(
            "BNB_USD",
            0x2f95862b045670cd22bee3114c39763a4a08beeb663b145d283c31d7d1101c4f,
            10,        // maxOIPercentage: 1000 (10%)
            50000e6,   // 50000 USDC max
            2,
            75
        );
        addPairInternal(
            "HYPE_USD",
            0x4279e31cc369bbcc2faf022b382b080e32a8e689ff20fbc530d2a603eb6cd98b,
            2,         // maxOIPercentage: 200 (2%)
            50000e6,   // 50000 USDC max
            2,
            75
        );
        
        // 50x Leverage Pairs - Crypto
        addPairInternal(
            "MON_USD",
            0x31491744e2dbf6df7fcf4ac0820d18a609b49076d45066d3568424e62f686cd1,
            3,         // maxOIPercentage: 300 (3%)
            50000e6,   // 50000 USDC max
            2,
            50
        );
        addPairInternal(
            "XRP_USD",
            0xec5d399846a9209f3fe5881d70aae9268c94339ff9817e8d18ff19fa05eea1c8,
            5,         // maxOIPercentage: 500 (5%)
            50000e6,   // 50000 USDC max
            2,
            50
        );
        addPairInternal(
            "SUI_USD",
            0x23d7315113f5b1d3ba7a83604c44b94d79f4fd69af77f804fc7f920a6dc65744,
            5,         // maxOIPercentage: 500 (5%)
            50000e6,   // 50000 USDC max
            2,
            50
        );
        addPairInternal(
            "OP_USD",
            0x385f64d993f7b77d8182ed5003d97c60aa3361f3cecfe711544d2d59165e9bdf,
            5,         // maxOIPercentage: 500 (5%)
            50000e6,   // 50000 USDC max
            2,
            50
        );
        addPairInternal(
            "ARB_USD",
            0x3fa4252848f9f0a1480be62745a4629d9eb1322aebab8a791e344b3b9c1adcf5,
            5,         // maxOIPercentage: 500 (5%)
            50000e6,   // 50000 USDC max
            2,
            50
        );
        addPairInternal(
            "ZRO_USD",
            0x3bd860bea28bf982fa06bcf358118064bb114086cc03993bd76197eaab0b8018,
            2,         // maxOIPercentage: 200 (2%)
            50000e6,   // 50000 USDC max
            2,
            50
        );
        addPairInternal(
            "JUP_USD",
            0x0a0408d619e9380abad35060f9192039ed5042fa6f82301d0e48bb52be830996,
            3,         // maxOIPercentage: 300 (3%)
            50000e6,   // 50000 USDC max
            2,
            50
        );
        addPairInternal(
            "LINK_USD",
            0x8ac0c70fff57e9aefdf5edf44b51d62c2d433653cbb2cf5cc06bb115af04d221,
            5,         // maxOIPercentage: 500 (5%)
            50000e6,   // 50000 USDC max
            2,
            50
        );
        
        // 25x Leverage Pairs - Crypto
        addPairInternal(
            "PYTH_USD",
            0x0bbf28e9a841a1cc788f6a361b17ca072d0ea3098a1e5df1c3922d06719579ff,
            3,         // maxOIPercentage: 300 (3%)
            50000e6,   // 50000 USDC max
            2,
            25
        );
        addPairInternal(
            "DOGE_USD",
            0xdcef50dd0a4cd2dcc17e45df1676dcb336a11a61c69df7a0299b0150c672d25c,
            5,         // maxOIPercentage: 500 (5%)
            50000e6,   // 50000 USDC max
            2,
            25
        );
        addPairInternal(
            "SHIB_USD",
            0xf0d57deca57b3da2fe63a493f4c25925fdfd8edf834b20f93e1f84dbd1504d4a,
            2,         // maxOIPercentage: 200 (2%)
            50000e6,   // 50000 USDC max
            2,
            25
        );
        addPairInternal(
            "BONK_USD",
            0x72b021217ca3fe68922a19aaf990109cb9d84e9ad004b4d2025ad6f529314419,
            2,         // maxOIPercentage: 200 (2%)
            50000e6,   // 50000 USDC max
            2,
            25
        );
        addPairInternal(
            "PEPE_USD",
            0xd69731a2e74ac1ce884fc3890f7ee324b6deb66147055249568869ed700882e4,
            2,         // maxOIPercentage: 200 (2%)
            50000e6,   // 50000 USDC max
            2,
            25
        );
        
        // Equities - 25x Leverage
        addPairInternal(
            "META_USD",
            0x78a3e3b8e676a8f73c439f5d749737034b139bbbe899ba5775216fba596607fe,
            10,        // maxOIPercentage: 1000 (10%)
            50000e6,   // 50000 USDC max
            2,
            25
        );
        addPairInternal(
            "TSLA_USD",
            0x16dad506d7db8da01c87581c87ca897a012a153557d4d578c3b9c9e1bc0632f1,
            10,        // maxOIPercentage: 1000 (10%)
            50000e6,   // 50000 USDC max
            2,
            25
        );
        addPairInternal(
            "NVDA_USD",
            0xb1073854ed24cbc755dc527418f52b7d271f6cc967bbf8d8129112b18860a593,
            5,         // maxOIPercentage: 500 (5%)
            50000e6,   // 50000 USDC max
            2,
            5
        );
        addPairInternal(
            "MSFT_USD",
            0xd0ca23c1cc005e004ccf1db5bf76aeb6a49218f43dac3d4b275e92de12ded4d1,
            10,        // maxOIPercentage: 1000 (10%)
            50000e6,   // 50000 USDC max
            2,
            25
        );
        addPairInternal(
            "COIN_USD",
            0xfee33f2a978bf32dd6b662b65ba8083c6773b494f8401194ec1870c640860245,
            8,         // maxOIPercentage: 800 (8%)
            50000e6,   // 50000 USDC max
            2,
            25
        );
        addPairInternal(
            "GOOGL_USD",
            0x5a48c03e9b9cb337801073ed9d166817473697efff0d138874e0f6a33d6d5aa6,
            10,        // maxOIPercentage: 1000 (10%)
            50000e6,   // 50000 USDC max
            2,
            25
        );
        addPairInternal(
            "AAPL_USD",
            0x49f6b65cb1de6b10eaf75e7c03ca029c306d0357e91b5311b175084a5ad55688,
            10,        // maxOIPercentage: 1000 (10%)
            50000e6,   // 50000 USDC max
            2,
            25
        );
        addPairInternal(
            "AMZN_USD",
            0xb5d0e0fa58a1f8b81498ae670ce93c872d14434b72c364885d4fa1b257cbb07a,
            10,        // maxOIPercentage: 1000 (10%)
            50000e6,   // 50000 USDC max
            2,
            25
        );
        
        // ============================================================
        // FOREX PAIRS (100x leverage)
        // ============================================================
        
        addPairInternal(
            "EURUSD",
            0xa995d00bb36a63cef7fd2c287dc105fc8f3d93779f062f09551b0af3e81ec30b,
            20,        // maxOIPercentage: 2000 (20%)
            50000e6,   // 50000 USDC max
            2,
            100
        );
        addPairInternal(
            "GBPUSD",
            0x84c2dde9633d93d1bcad84e7dc41c9d56578b7ec52fabedc1f335d673df0a7c1,
            15,        // maxOIPercentage: 1500 (15%)
            50000e6,   // 50000 USDC max
            2,
            100
        );
        addPairInternal(
            "USDJPY",
            0xef2c98c804ba503c6a707e38be4dfbb16683775f195b091252bf24693042fd52,
            15,        // maxOIPercentage: 1500 (15%)
            50000e6,   // 50000 USDC max
            2,
            100
        );
        addPairInternal(
            "AUDUSD",
            0x67a6f93030420c1c9e3fe37c1ab6b77966af82f995944a9fefce357a22854a80,
            10,        // maxOIPercentage: 1000 (10%)
            50000e6,   // 50000 USDC max
            2,
            100
        );
        addPairInternal(
            "USDCAD",
            0x3112b03a41c910ed446852aacf67118cb1bec67b2cd0b9a214c58cc0eaa2ecca,
            10,        // maxOIPercentage: 1000 (10%)
            50000e6,   // 50000 USDC max
            2,
            100
        );
        addPairInternal(
            "USDCHF",
            0x0b1e3297e69f162877b577b0d6a47a0d63b2392bc8499e6540da4187a63e28f8,
            10,        // maxOIPercentage: 1000 (10%)
            50000e6,   // 50000 USDC max
            2,
            100
        );
        addPairInternal(
            "NZDUSD",
            0x92eea8ba1b00078cdc2ef6f64f091f262e8c7d0576ee4677572f314ebfcc9806,
            8,         // maxOIPercentage: 800 (8%)
            50000e6,   // 50000 USDC max
            2,
            100
        );
        
        // ============================================================
        // COMMODITIES PAIRS (100x leverage)
        // ============================================================
        
        addPairInternal(
            "XAG_USD",
            0xf2fb02c32b055c805e7238d628e5e9dadef274376114eb1f012337cabe93871e,
            10,        // maxOIPercentage: 1000 (10%)
            2000e6,    // 2000 USDC max
            2,
            100
        );
        addPairInternal(
            "XAU_USD",
            0x765d2ba906dbc32ca17cc11f5310a89e9ee1f6420508c63861f2f8ba4ee34bb2,
            10,        // maxOIPercentage: 1000 (10%)
            2000e6,    // 2000 USDC max
            2,
            100
        );
    }

    function addPairInternal(
        string memory pairs,
        bytes32 pythTokenId,
        uint256 oiRatio,
        uint256 maxPositionSize,
        uint256 minLeverage,
        uint256 maxLeverage
    ) internal {
        pairInfo[pairs] = PairInfo(pairs, pythTokenId, true, oiRatio, maxPositionSize, minLeverage, maxLeverage);
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
        
        return (poolValue * ONE) / totalSupply;
    }

    // Helper function to calculate how much ppUSDC user would get for a deposit
    function calculateDepositShares(uint256 depositAmount) external view returns (uint256) {
        require(depositAmount > 0, "Amount must be > 0");
        
        uint256 totalSupply = ppUSDC.totalSupply();
        uint256 currentTVL = getPoolValue();
        
        if (totalSupply == 0) {
            return depositAmount; // 1:1 for first deposit
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

    // Helper function to debug withdrawal calculations with detailed breakdown
    function debugWithdrawDetailed(uint256 ppUSDCAmount) external view returns (
        uint256 userBalance,
        uint256 totalSupply,
        uint256 currentTVL,
        uint256 contractBalance,
        uint256 _totalOpenMargin,
        uint256 _secondaryVaultBalance,
        uint256 reserved,
        uint256 calculatedUSDC,
        uint256 userPercentage,
        uint256 expectedRatio, // What the ratio should be (1e18 = 1:1)
        uint256 actualRatio    // What the actual ratio is
    ) {
        userBalance = ppUSDC.balanceOf(msg.sender);
        totalSupply = ppUSDC.totalSupply();
        currentTVL = getPoolValue();
        contractBalance = usdc.balanceOf(address(this));
        _totalOpenMargin = totalOpenMargin;
        _secondaryVaultBalance = secondaryVaultBalance;
        reserved = totalOpenMargin + secondaryVaultBalance;
        calculatedUSDC = totalSupply > 0 ? (ppUSDCAmount * currentTVL) / totalSupply : 0;
        userPercentage = totalSupply > 0 ? (ppUSDCAmount * 10000) / totalSupply : 0;
        
        // Calculate expected vs actual ratios
        expectedRatio = ONE; // 1:1 ratio expected
        actualRatio = totalSupply > 0 ? (currentTVL * ONE) / totalSupply : ONE;
    }

    // Helper function to get user's percentage ownership of the pool
    function getUserPoolPercentage(address user) external view returns (uint256) {
        uint256 userBalance = ppUSDC.balanceOf(user);
        uint256 totalSupply = ppUSDC.totalSupply();
        
        if (totalSupply == 0) return 0;
        
        // Return percentage with 4 decimal places (10000 = 100%)
        return (userBalance * 10000) / totalSupply;
    }

    // Function to check pool health and identify potential issues
    function checkPoolHealth() external view returns (
        bool isHealthy,
        string memory issue,
        uint256 contractBalance,
        uint256 totalSupply,
        uint256 currentTVL,
        uint256 ppUSDCPrice,
        uint256 totalReserved
    ) {
        contractBalance = usdc.balanceOf(address(this));
        totalSupply = ppUSDC.totalSupply();
        currentTVL = getPoolValue();
        totalReserved = totalOpenMargin + secondaryVaultBalance;
        
        isHealthy = true;
        issue = "Pool is healthy";
        
        // Calculate ppUSDC price
        ppUSDCPrice = totalSupply > 0 ? (currentTVL * ONE) / totalSupply : ONE;
        
        // Check for issues
        if (contractBalance < totalReserved) {
            isHealthy = false;
            issue = "Contract balance less than reserved amounts";
        } else if (currentTVL == 0 && totalSupply > 0) {
            isHealthy = false;
            issue = "Pool has no value but ppUSDC tokens exist";
        } else if (ppUSDCPrice > ONE * 2) {
            isHealthy = false;
            issue = "ppUSDC price too high - possible calculation error";
        } else if (ppUSDCPrice < ONE / 2 && totalSupply > 0) {
            isHealthy = false;
            issue = "ppUSDC price too low - possible pool drain";
        }
    }

    function depositLP(uint256 amount) external {
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
    ) external payable {
        require(margin > 0 && leverage > 0);
        PairInfo storage info = pairInfo[pairs];
        require(info.active);

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

        // Validate Take Profit and Stop Loss levels before opening position
        if (takeProfit > 0) {
            if (isLong) {
                // Long position: TP must be ABOVE entry price (profit when price goes up)
                require(takeProfit > oraclePrice, "Long TP must be above entry price");
            } else {
                // Short position: TP must be BELOW entry price (profit when price goes down)
                require(takeProfit < oraclePrice, "Short TP must be below entry price");
            }
        }

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
        if (takeProfit > 0 && stopLoss > 0) {
            require(takeProfit != stopLoss, "TP and SL cannot be the same price");
        }

        // Additional validation: Ensure reasonable distance from entry price (prevent dust orders)
        uint256 minDistance = oraclePrice / 1000; // 0.1% minimum distance
        if (takeProfit > 0) {
            if (isLong) {
                require(takeProfit >= oraclePrice + minDistance, "TP too close to entry price");
            } else {
                require(takeProfit <= oraclePrice - minDistance, "TP too close to entry price");
            }
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
        uint256 newSL
    ) external {
        Position[] storage userPositions = positions[msg.sender];

        for (uint256 i = 0; i < userPositions.length; i++) {
            Position storage pos = userPositions[i];

            if (pos.id == positionId && !pos.isClosed) {
                // Get current price to validate TP/SL levels
                PythStructs.Price memory priceData = pyth.getPriceUnsafe(pos.pythTokenId);
                require(priceData.price > 0, "Invalid oracle price");
                uint256 currentPrice = toUint(priceData.price);

                // Validate Take Profit (TP) - must be in profit direction
                if (newTP > 0) {
                    if (pos.isLong) {
                        // Long position: TP must be ABOVE current price (profit when price goes up)
                        require(newTP > currentPrice, "Long TP must be above current price");
                    } else {
                        // Short position: TP must be BELOW current price (profit when price goes down)
                        require(newTP < currentPrice, "Short TP must be below current price");
                    }
                }

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
                if (newTP > 0 && newSL > 0) {
                    require(newTP != newSL, "TP and SL cannot be the same price");
                }

                // Additional validation: Ensure reasonable distance from current price (prevent dust orders)
                uint256 minDistance = currentPrice / 1000; // 0.1% minimum distance
                if (newTP > 0) {
                    if (pos.isLong) {
                        require(newTP >= currentPrice + minDistance, "TP too close to current price");
                    } else {
                        require(newTP <= currentPrice - minDistance, "TP too close to current price");
                    }
                }
                if (newSL > 0) {
                    if (pos.isLong) {
                        require(newSL <= currentPrice - minDistance, "SL too close to current price");
                    } else {
                        require(newSL >= currentPrice + minDistance, "SL too close to current price");
                    }
                }

                // Update the TP/SL values
                pos.takeProfit = newTP;
                pos.stopLoss = newSL;

                emit TPSLModified(positionId, msg.sender, newTP, newSL);
                emit TPSLValidated(positionId, msg.sender, currentPrice, newTP, newSL, pos.isLong, "modify");
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
            int256 maxPnl = int256((pos.margin * MAX_PNL_RATIO) / ONE);
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

                if (!pos.isClosed) {
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

        // Update total ratio
        totalOIRatio = totalOIRatio - info.oiRatio + oiRatio;
        
        info.oiRatio = oiRatio;
        info.maxPositionSize = maxPositionSize;
        info.minLeverage = minLeverage;
        info.maxLeverage = maxLeverage;

        emit PairConfigUpdated(pairs, oiRatio, maxPositionSize, minLeverage, maxLeverage);
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

    /**
     * @notice Add a new trading pair (owner only)
     * @param pairs Trading pair name
     * @param pythTokenId Pyth price feed ID
     * @param oiRatio OI ratio weight
     * @param maxPositionSize Max position size in USDC
     * @param minLeverage Minimum leverage
     * @param maxLeverage Maximum leverage
     */
    function addPair(
        string calldata pairs,
        bytes32 pythTokenId,
        uint256 oiRatio,
        uint256 maxPositionSize,
        uint256 minLeverage,
        uint256 maxLeverage
    ) external onlyOwner {
        require(bytes(pairInfo[pairs].name).length == 0, "Pair already exists");
        require(minLeverage > 0 && maxLeverage > 0, "Invalid leverage");
        require(minLeverage <= maxLeverage, "Min leverage > max leverage");
        require(oiRatio > 0, "Invalid OI ratio");
        require(maxPositionSize > 0, "Invalid position size");

        addPairInternal(pairs, pythTokenId, oiRatio, maxPositionSize, minLeverage, maxLeverage);
    }

    event PairConfigUpdated(
        string pairs,
        uint256 maxOIPercentage,
        uint256 maxPositionSize,
        uint256 minLeverage,
        uint256 maxLeverage
    );

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

    /**
     * @notice Get OI information for all pairs
     * @return pairNames Array of pair names
     * @return maxOIPerSides Array of max OI per side
     * @return currentLongOIs Array of current long OIs
     * @return currentShortOIs Array of current short OIs
     * @return availableLongOIs Array of available long OIs
     * @return availableShortOIs Array of available short OIs
     */
    function getAllPairsOI()
        external
        view
        returns (
            string[] memory pairNames,
            uint256[] memory maxOIPerSides,
            uint256[] memory currentLongOIs,
            uint256[] memory currentShortOIs,
            uint256[] memory availableLongOIs,
            uint256[] memory availableShortOIs
        )
    {
        uint256 length = allPairs.length;
        pairNames = new string[](length);
        maxOIPerSides = new uint256[](length);
        currentLongOIs = new uint256[](length);
        currentShortOIs = new uint256[](length);
        availableLongOIs = new uint256[](length);
        availableShortOIs = new uint256[](length);
        
        uint256 poolValue = getPoolValue();
        
        for (uint256 i = 0; i < length; i++) {
            PairInfo storage info = allPairs[i];
            PairFunding storage pf = pairFunding[info.name];
            
            pairNames[i] = info.name;
            
            if (totalOIRatio > 0) {
                // Calculate max OI based on ratio
                uint256 maxAllowedOI = (poolValue * info.oiRatio) / totalOIRatio;
                maxOIPerSides[i] = maxAllowedOI / 2;
            } else {
                maxOIPerSides[i] = 0;
            }
            
            currentLongOIs[i] = pf.oiLong;
            currentShortOIs[i] = pf.oiShort;
            
            availableLongOIs[i] = maxOIPerSides[i] > pf.oiLong ? maxOIPerSides[i] - pf.oiLong : 0;
            availableShortOIs[i] = maxOIPerSides[i] > pf.oiShort ? maxOIPerSides[i] - pf.oiShort : 0;
        }
    }
}

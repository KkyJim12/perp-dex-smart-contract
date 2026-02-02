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

    uint256 public constant MAX_DAILY_FUNDING_BPS = 100;
    uint256 public constant FUNDING_MAX_PER_SEC =
        ((ONE * MAX_DAILY_FUNDING_BPS) / 10000) / 86400;

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
    }

    mapping(address => Position[]) public positions;
    mapping(address => string) public username;
    mapping(string => address) public usernameTaken;
    mapping(string => PairFunding) public pairFunding;
    mapping(string => PairInfo) public pairInfo;

    PairInfo[] public allPairs;
    address[] public allUsers;

    uint256 public totalOpenMargin;

    // LP deposit tracking for time lock
    mapping(address => uint256) public lastDepositTime;
    uint256 public constant WITHDRAW_DELAY = 1 hours; // Minimum time before withdrawal

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
        uint256 bal = usdc.balanceOf(address(this));
        // Subtract both open margin and secondary vault balance from main pool
        uint256 reserved = totalOpenMargin + secondaryVaultBalance;
        return bal > reserved ? bal - reserved : 0;
    }

    function getppUSDCPrice() external view returns (uint256) {
        uint256 totalSupply = ppUSDC.totalSupply();
        if (totalSupply == 0) return ONE;
        uint256 pool = getPoolValue();
        return (pool * ONE) / totalSupply;
    }

    function depositLP(uint256 amount) external {
        require(amount > 0, "Amount must be > 0");
        uint256 poolBefore = getPoolValue();
        uint256 totalSupply = ppUSDC.totalSupply();

        // Calculate ppUSDC to mint
        uint256 ppUSDCToMint = (totalSupply == 0 || poolBefore == 0)
            ? amount
            : (amount * totalSupply) / poolBefore;

        require(ppUSDCToMint > 0, "Shares must be > 0");

        // Transfer USDC from user
        require(
            usdc.transferFrom(msg.sender, address(this), amount),
            "Transfer failed"
        );

        // Mint ppUSDC to user
        ppUSDC.mint(msg.sender, ppUSDCToMint);

        // Record deposit time for withdraw delay
        lastDepositTime[msg.sender] = block.timestamp;

        emit LPDeposit(msg.sender, amount, ppUSDCToMint);
    }

    function withdrawLP(uint256 ppUSDCAmount) external {
        require(ppUSDCAmount > 0, "Amount must be > 0");
        
        // Enforce withdraw delay to prevent exploit
        require(
            block.timestamp >= lastDepositTime[msg.sender] + WITHDRAW_DELAY,
            "Withdraw delay not met"
        );
        
        uint256 userBalance = ppUSDC.balanceOf(msg.sender);
        require(userBalance >= ppUSDCAmount, "Insufficient ppUSDC");

        uint256 pool = getPoolValue();
        require(pool > 0, "Pool empty");

        uint256 totalSupply = ppUSDC.totalSupply();
        
        // Calculate USDC to return based on ppUSDC amount
        uint256 usdcAmount = (ppUSDCAmount * pool) / totalSupply;
        require(usdcAmount > 0, "Amount must be > 0");

        // Burn ppUSDC from user
        ppUSDC.burn(msg.sender, ppUSDCAmount);

        // Transfer USDC to user
        require(usdc.transfer(msg.sender, usdcAmount), "Transfer failed");

        emit LPWithdraw(msg.sender, usdcAmount, ppUSDCAmount);
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
    // FUNDING
    // ------------------------------------------------------------------

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

        uint256 totalOI = pf.oiLong + pf.oiShort;
        if (totalOI == 0) {
            pf.lastUpdate = block.timestamp;
            return;
        }

        uint256 diff = pf.oiLong > pf.oiShort
            ? pf.oiLong - pf.oiShort
            : pf.oiShort - pf.oiLong;
        uint256 imbalanceRatio = (diff * ONE) / totalOI;

        uint256 magPerSec = (FUNDING_MAX_PER_SEC * imbalanceRatio) / ONE;
        int256 signedPerSec = pf.oiLong >= pf.oiShort
            ? int256(magPerSec)
            : -int256(magPerSec);

        pf.growth += signedPerSec * int256(dt);
        pf.lastUpdate = block.timestamp;
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
        uint256 netSize = netMargin * leverage;

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

                bool hitTP = false;
                bool hitSL = false;
                string memory status = "";
                uint256 closePrice = currentPrice; // Default to current price

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

                int256 pnl = pos.isLong
                    ? (int256(pos.size) *
                        (int256(price) - int256(pos.entryPrice))) /
                        int256(pos.entryPrice)
                    : (int256(pos.size) *
                        (int256(pos.entryPrice) - int256(price))) /
                        int256(pos.entryPrice);

                PairFunding storage pf = pairFunding[pos.pairs];
                int256 fundingPayment = (int256(pos.size) *
                    (pf.growth - pos.fundingEntry)) / int256(ONE);

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
}

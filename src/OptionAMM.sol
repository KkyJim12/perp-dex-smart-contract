// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {Ownable2Step} from "lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {PythStructs} from "lib/pyth-sdk-solidity/PythStructs.sol";

interface IOpUSDC is IERC20 {
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
    function optionAMM() external view returns (address);
}

/// @dev The deployed oracle must support unique historical boundary parsing.
interface IOptionPyth {
    function getUpdateFee(bytes[] calldata data) external view returns (uint256);
    function updatePriceFeeds(bytes[] calldata data) external payable;
    function getPriceNoOlderThan(bytes32 id, uint256 age) external view returns (PythStructs.Price memory);
    function parsePriceFeedUpdatesUnique(bytes[] calldata data, bytes32[] calldata ids, uint64 minTime, uint64 maxTime)
        external
        payable
        returns (PythStructs.PriceFeed[] memory);
}

/// @notice Capped European option vault: buy a long for a premium, or sell it back before expiry.
/// @dev Cash/notionals have 6 decimals, USD prices 18. Eight-step binomial quotes assume zero interest.
contract OptionAMM is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 public constant WAD = 1e18;
    uint256 public constant MAX_UTILIZATION_BPS = 8_000;
    uint256 public constant MAX_CONFIDENCE_BPS = 100;
    uint256 public constant MAX_PRICE_AGE = 5;
    uint256 public constant MAX_TRADERS_PER_MARKET = 128;
    uint256 public constant MIN_NOTIONAL = 1e6;
    uint256 public constant SHARE_OFFSET = 1e6;
    uint256 public constant MAX_PRICE = 1e30;
    uint256 public constant YEAR = 365 days;
    uint256 public constant PRICING_STEPS = 8;
    uint256 public constant AUTO_PAYOUT_GAS = 100_000;
    uint64 public constant ORACLE_WINDOW = 30;
    uint64 public constant TRADING_CUTOFF = 5;

    enum Status {
        Scheduled,
        Trading,
        Finalized,
        Cancelled
    }

    struct Pair {
        string name;
        bytes32 priceId;
        bool active;
    }

    struct Market {
        uint256 pairId;
        Status status;
        uint64 startTime;
        uint64 endTime;
        bool isCall;
        uint256 strikePrice; // Zero at scheduling selects the authenticated opening price.
        uint256 openingPrice;
        uint256 closingPrice;
        uint256 volatilityBps;
        uint256 feeBps;
        uint256 outstanding; // Maximum payout, not mark-to-market liability.
    }

    IERC20 public immutable usdc;
    IOptionPyth public immutable pyth;
    IOpUSDC public immutable opUSDC;
    Pair[] public pairs;
    Market[] private markets;
    mapping(address => bool) public authorizedBackends;
    mapping(bytes32 => bool) private activeNames;
    mapping(bytes32 => bool) private activeFeeds;
    mapping(bytes32 => bool) public scheduled;
    mapping(uint256 => mapping(address => uint256)) public optionBalance;
    mapping(uint256 => address[]) public traders;
    mapping(uint256 => mapping(address => bool)) private registeredTrader;
    mapping(address => uint256) public claimable;
    mapping(address => uint256) public withdrawalRequests;
    uint256 public reservedPayout;
    uint256 public unresolvedExposureMarkets;
    uint256 public totalClaimable;
    uint256 public queuedWithdrawalShares;
    uint256 public vaultPremiums;
    uint256 public vaultSaleProceeds;
    uint256 public vaultPayouts;
    uint256 public totalFees;
    bool public tradingPaused;

    event BackendAuthorized(address indexed backend, bool authorized);
    event PairAdded(uint256 indexed pairId, string name, bytes32 priceId);
    event PairRemoved(uint256 indexed pairId);
    event MarketCreated(
        uint256 indexed marketId,
        uint256 indexed pairId,
        uint64 startTime,
        uint64 endTime,
        uint256 strikePrice,
        bool isCall,
        uint256 volatilityBps,
        uint256 feeBps
    );
    event MarketOpened(uint256 indexed marketId, uint256 openingPrice, uint256 strikePrice);
    event MarketFinalized(uint256 indexed marketId, uint256 closingPrice, uint256 liability);
    event MarketCancelled(uint256 indexed marketId);
    event Bought(
        uint256 indexed marketId, address indexed trader, uint256 contracts, uint256 premium, uint256 fee, uint256 price
    );
    event Sold(
        uint256 indexed marketId,
        address indexed trader,
        uint256 contracts,
        uint256 proceeds,
        uint256 fee,
        uint256 price
    );
    event Paid(uint256 indexed marketId, address indexed trader, uint256 assets);
    event PayoutDeferred(uint256 indexed marketId, address indexed trader, uint256 assets);
    event Claimed(address indexed trader, uint256 assets);
    event LPDeposited(address indexed lp, uint256 assets, uint256 shares);
    event LPWithdrawn(address indexed lp, uint256 assets, uint256 shares);
    event WithdrawalRequested(address indexed lp, uint256 shares);
    event WithdrawalCancelled(address indexed lp, uint256 shares);
    event WithdrawalDeferred(address indexed lp, uint256 assets);
    event TradingPaused(bool paused);

    modifier onlyOperator() {
        require(msg.sender == owner() || authorizedBackends[msg.sender], "Not authorized backend");
        _;
    }

    constructor(address usdc_, address pyth_, address opUSDC_) Ownable(msg.sender) {
        require(usdc_.code.length > 0 && pyth_.code.length > 0 && opUSDC_.code.length > 0, "Invalid contract");
        require(
            IERC20Metadata(usdc_).decimals() == 6 && IERC20Metadata(opUSDC_).decimals() == 6,
            "Tokens must have 6 decimals"
        );
        usdc = IERC20(usdc_);
        pyth = IOptionPyth(pyth_);
        opUSDC = IOpUSDC(opUSDC_);
    }

    function authorizeBackend(address backend, bool authorized) external onlyOwner {
        require(backend != address(0), "Invalid backend");
        authorizedBackends[backend] = authorized;
        emit BackendAuthorized(backend, authorized);
    }

    function setTradingPaused(bool paused) external onlyOwner {
        tradingPaused = paused;
        emit TradingPaused(paused);
    }

    function marketCount() external view returns (uint256) {
        return markets.length;
    }

    function getMarket(uint256 id) external view returns (Market memory) {
        return markets[id];
    }

    function traderCount(uint256 id) external view returns (uint256) {
        return traders[id].length;
    }

    function pairCount() external view returns (uint256) {
        return pairs.length;
    }

    function priceIds(uint256 pairId) external view returns (bytes32) {
        return pairs[pairId].priceId;
    }

    function addPair(string calldata name, bytes32 priceId) external onlyOwner returns (uint256 pairId) {
        require(bytes(name).length > 0 && priceId != bytes32(0), "Invalid pair");
        bytes32 nameHash = keccak256(bytes(name));
        require(!activeNames[nameHash] && !activeFeeds[priceId], "Duplicate pair");
        activeNames[nameHash] = true;
        activeFeeds[priceId] = true;
        pairId = pairs.length;
        pairs.push(Pair(name, priceId, true));
        emit PairAdded(pairId, name, priceId);
    }

    function removePair(uint256 pairId) external onlyOwner {
        Pair storage pair = pairs[pairId];
        require(pair.active, "Pair inactive");
        pair.active = false;
        activeNames[keccak256(bytes(pair.name))] = false;
        activeFeeds[pair.priceId] = false;
        emit PairRemoved(pairId);
    }

    /// @notice Backend schedules a UTC-aligned call or put with immutable strike, volatility and spread.
    function createMarket(
        uint256 pairId,
        uint64 duration,
        uint64 startTime,
        uint256 strikePrice,
        uint256 volatilityBps,
        uint256 feeBps,
        bool isCall
    ) external onlyOperator returns (uint256 id) {
        require(pairId < pairs.length && pairs[pairId].active, "Pair inactive");
        require(
            duration == 1 days || duration == 3 days || duration == 7 days || duration == 14 days
                || duration == 30 days,
            "Invalid duration"
        );
        require(startTime > block.timestamp && startTime % duration == 0, "Invalid start");
        require(strikePrice <= MAX_PRICE, "Invalid strike");
        require(volatilityBps >= 100 && volatilityBps <= 50_000, "Invalid volatility");
        require(feeBps <= 500, "Fee exceeds 5%");
        bytes32 key = keccak256(abi.encode(pairId, duration, startTime, strikePrice, isCall));
        require(!scheduled[key], "Round exists");
        scheduled[key] = true;
        id = markets.length;
        markets.push(
            Market(
                pairId,
                Status.Scheduled,
                startTime,
                startTime + duration,
                isCall,
                strikePrice,
                0,
                0,
                volatilityBps,
                feeBps,
                0
            )
        );
        emit MarketCreated(id, pairId, startTime, startTime + duration, strikePrice, isCall, volatilityBps, feeBps);
    }

    function openMarket(uint256 id, bytes[] calldata data) external payable onlyOperator nonReentrant {
        Market storage m = markets[id];
        require(m.status == Status.Scheduled, "Not scheduled");
        require(
            block.timestamp >= m.startTime && block.timestamp <= m.startTime + ORACLE_WINDOW, "Opening window closed"
        );
        m.openingPrice = _boundaryPrice(m.pairId, m.startTime, data);
        if (m.strikePrice == 0) m.strikePrice = m.openingPrice;
        m.status = Status.Trading;
        emit MarketOpened(id, m.openingPrice, m.strikePrice);
    }

    function cancelMarket(uint256 id) external onlyOperator {
        Market storage m = markets[id];
        require(
            (m.status == Status.Scheduled || m.status == Status.Trading) && m.outstanding == 0,
            "Market has exposure or closed"
        );
        m.status = Status.Cancelled;
        emit MarketCancelled(id);
    }

    /// @notice Conservative unreserved LP equity; deferred payouts remain excluded.
    function vaultValue() public view returns (uint256) {
        return usdc.balanceOf(address(this)) - reservedPayout - totalClaimable;
    }

    function availableLiquidity() external view returns (uint256) {
        return vaultValue();
    }

    function previewDeposit(uint256 assets) public view returns (uint256) {
        return Math.mulDiv(assets, opUSDC.totalSupply() + SHARE_OFFSET, vaultValue() + 1);
    }

    function previewRedeem(uint256 shares) public view returns (uint256) {
        return Math.mulDiv(shares, vaultValue() + 1, opUSDC.totalSupply() + SHARE_OFFSET);
    }

    function lpShareValue(address lp) external view returns (uint256) {
        return previewRedeem(opUSDC.balanceOf(lp) + withdrawalRequests[lp]);
    }

    function deposit(uint256 assets, uint256 minShares) external nonReentrant returns (uint256 shares) {
        require(unresolvedExposureMarkets == 0, "Unresolved markets lock LPs");
        require(opUSDC.optionAMM() == address(this), "LP token not wired");
        require(assets > 0, "Zero assets");
        shares = previewDeposit(assets);
        require(shares > 0 && shares >= minShares, "Share slippage");
        _receiveUSDC(assets);
        opUSDC.mint(msg.sender, shares);
        emit LPDeposited(msg.sender, assets, shares);
    }

    function withdraw(uint256 shares, uint256 minAssets) external nonReentrant returns (uint256 assets) {
        require(unresolvedExposureMarkets == 0, "Unresolved markets lock LPs");
        require(shares > 0, "Zero shares");
        assets = previewRedeem(shares);
        require(assets > 0 && assets >= minAssets, "Asset slippage");
        opUSDC.burn(msg.sender, shares);
        usdc.safeTransfer(msg.sender, assets);
        emit LPWithdrawn(msg.sender, assets, shares);
    }

    /// @notice Escrow LP shares and halt new buys until pending exits are executed.
    function requestWithdrawal(uint256 shares) external nonReentrant {
        require(shares > 0, "Zero shares");
        require(previewRedeem(shares) >= MIN_NOTIONAL, "Withdrawal too small");
        IERC20(address(opUSDC)).safeTransferFrom(msg.sender, address(this), shares);
        withdrawalRequests[msg.sender] += shares;
        queuedWithdrawalShares += shares;
        emit WithdrawalRequested(msg.sender, shares);
    }

    function cancelWithdrawal() external nonReentrant {
        uint256 shares = withdrawalRequests[msg.sender];
        require(shares > 0, "No withdrawal request");
        delete withdrawalRequests[msg.sender];
        queuedWithdrawalShares -= shares;
        IERC20(address(opUSDC)).safeTransfer(msg.sender, shares);
        emit WithdrawalCancelled(msg.sender, shares);
    }

    /// @notice Anyone can process an exit after exposure closes; payment goes to the requesting LP.
    function executeWithdrawal(address lp) external nonReentrant returns (uint256 assets) {
        require(unresolvedExposureMarkets == 0, "Unresolved markets lock LPs");
        uint256 shares = withdrawalRequests[lp];
        require(shares > 0, "No withdrawal request");
        assets = previewRedeem(shares);
        delete withdrawalRequests[lp];
        queuedWithdrawalShares -= shares;
        opUSDC.burn(address(this), shares);
        if (assets > 0) {
            try this.paySettlement{gas: AUTO_PAYOUT_GAS}(lp, assets) {}
            catch {
                claimable[lp] += assets;
                totalClaimable += assets;
                emit WithdrawalDeferred(lp, assets);
            }
        }
        emit LPWithdrawn(lp, assets, shares);
    }

    /// @notice Model premium per USDC of notional, scaled by 1e18, before the bid/ask spread.
    function optionValue(uint256 id, uint256 currentPrice) public view returns (uint256) {
        Market storage m = markets[id];
        _tradable(m);
        require(currentPrice > 0 && currentPrice <= MAX_PRICE, "Invalid price");
        uint256 horizon = Math.sqrt(Math.mulDiv(m.endTime - block.timestamp, WAD * WAD, YEAR * PRICING_STEPS));
        uint256 up = WAD + Math.mulDiv(m.volatilityBps * 1e14, horizon, WAD);
        uint256 probability = WAD * WAD / (up + WAD); // d=1/u, p=(1-d)/(u-d)=1/(u+1).
        uint256 upSquared = Math.mulDiv(up, up, WAD);
        uint256 spot = currentPrice;
        uint256[9] memory values;
        for (uint256 i; i < PRICING_STEPS; ++i) {
            spot = Math.mulDiv(spot, WAD, up);
        }
        for (uint256 i; i <= PRICING_STEPS; ++i) {
            values[i] = _payoff(m, spot, WAD);
            spot = Math.mulDiv(spot, upSquared, WAD);
        }
        for (uint256 step = PRICING_STEPS; step > 0; --step) {
            for (uint256 j; j < step; ++j) {
                values[j] = (values[j + 1] * probability + values[j] * (WAD - probability)) / WAD;
            }
        }
        return values[0];
    }

    function quoteBuy(uint256 id, uint256 contracts, uint256 currentPrice)
        public
        view
        returns (uint256 premium, uint256 fee)
    {
        require(contracts >= MIN_NOTIONAL, "Notional too small");
        uint256 fair = Math.mulDiv(contracts, optionValue(id, currentPrice), WAD, Math.Rounding.Ceil);
        require(fair > 0, "Premium too small");
        fee = Math.mulDiv(fair, markets[id].feeBps, BPS, Math.Rounding.Ceil);
        premium = fair + fee;
    }

    function quoteSell(uint256 id, uint256 contracts, uint256 currentPrice)
        public
        view
        returns (uint256 proceeds, uint256 fee)
    {
        require(contracts >= MIN_NOTIONAL, "Notional too small");
        uint256 fair = Math.mulDiv(contracts, optionValue(id, currentPrice), WAD);
        fee = Math.mulDiv(fair, markets[id].feeBps, BPS, Math.Rounding.Ceil);
        proceeds = fair - fee;
    }

    function buy(
        uint256 id,
        uint256 contracts,
        uint256 currentPrice,
        uint256 maxPremium,
        uint256 deadline,
        bytes[] calldata data
    ) external payable nonReentrant returns (uint256 premium) {
        require(block.timestamp <= deadline, "Deadline passed");
        require(queuedWithdrawalShares == 0, "LP withdrawals pending");
        require(opUSDC.totalSupply() > 0, "No LP liquidity");
        Market storage m = markets[id];
        _tradable(m);
        uint256 price = _currentPrice(m, data);
        require(price == currentPrice, "Price mismatch");
        uint256 fee;
        (premium, fee) = quoteBuy(id, contracts, price);
        require(premium <= maxPremium, "Premium exceeds limit");
        if (!registeredTrader[id][msg.sender]) {
            require(traders[id].length < MAX_TRADERS_PER_MARKET, "Market participant limit");
            registeredTrader[id][msg.sender] = true;
            traders[id].push(msg.sender);
        }
        uint256 beforeOutstanding = m.outstanding;
        m.outstanding += contracts;
        optionBalance[id][msg.sender] += contracts;
        reservedPayout += contracts;
        if (beforeOutstanding == 0) ++unresolvedExposureMarkets;
        _receiveUSDC(premium);
        require(
            reservedPayout <= Math.mulDiv(usdc.balanceOf(address(this)) - totalClaimable, MAX_UTILIZATION_BPS, BPS),
            "Vault utilization exceeded"
        );
        vaultPremiums += premium;
        totalFees += fee;
        emit Bought(id, msg.sender, contracts, premium, fee, price);
    }

    /// @notice Sell all or part of the caller's long back to the vault; no naked short positions.
    function sell(
        uint256 id,
        uint256 contracts,
        uint256 currentPrice,
        uint256 minProceeds,
        uint256 deadline,
        bytes[] calldata data
    ) external payable nonReentrant returns (uint256 proceeds) {
        require(block.timestamp <= deadline, "Deadline passed");
        Market storage m = markets[id];
        _tradable(m);
        require(contracts >= MIN_NOTIONAL && contracts <= optionBalance[id][msg.sender], "Invalid contracts");
        uint256 remainder = optionBalance[id][msg.sender] - contracts;
        require(remainder == 0 || remainder >= MIN_NOTIONAL, "Dust remainder");
        uint256 price = _currentPrice(m, data);
        require(price == currentPrice, "Price mismatch");
        uint256 fee;
        (proceeds, fee) = quoteSell(id, contracts, price);
        require(proceeds >= minProceeds, "Proceeds below limit");
        optionBalance[id][msg.sender] = remainder;
        m.outstanding -= contracts;
        reservedPayout -= contracts;
        if (m.outstanding == 0) --unresolvedExposureMarkets;
        vaultSaleProceeds += proceeds;
        totalFees += fee;
        if (proceeds > 0) usdc.safeTransfer(msg.sender, proceeds);
        emit Sold(id, msg.sender, contracts, proceeds, fee, price);
    }

    /// @notice Backend authenticates one expiry price and automatically pays remaining holders.
    /// @dev Failed transfers become funded claims, preserving other payouts and LP exits.
    function finalizeMarket(uint256 id, bytes[] calldata data) external payable onlyOperator nonReentrant {
        Market storage m = markets[id];
        require(m.status == Status.Trading && block.timestamp >= m.endTime, "Not finalizable");
        m.closingPrice = _boundaryPrice(m.pairId, m.endTime, data);
        m.status = Status.Finalized;
        if (m.outstanding != 0) --unresolvedExposureMarkets;
        reservedPayout -= m.outstanding;
        m.outstanding = 0;
        uint256 liability;
        address[] storage holders = traders[id];
        for (uint256 i; i < holders.length; ++i) {
            address holder = holders[i];
            uint256 contracts = optionBalance[id][holder];
            if (contracts == 0) continue;
            delete optionBalance[id][holder];
            uint256 assets = _payoff(m, m.closingPrice, contracts);
            liability += assets;
            if (assets != 0) {
                try this.paySettlement{gas: AUTO_PAYOUT_GAS}(holder, assets) {
                    emit Paid(id, holder, assets);
                } catch {
                    claimable[holder] += assets;
                    totalClaimable += assets;
                    emit PayoutDeferred(id, holder, assets);
                }
            } else {
                emit Paid(id, holder, 0);
            }
        }
        vaultPayouts += liability;
        emit MarketFinalized(id, m.closingPrice, liability);
    }

    /// @dev Self-call isolates reverting or false-return transfers so finalization can continue.
    function paySettlement(address recipient, uint256 assets) external {
        require(msg.sender == address(this), "Only self");
        usdc.safeTransfer(recipient, assets);
    }

    function claim() external nonReentrant returns (uint256 assets) {
        assets = claimable[msg.sender];
        require(assets > 0, "Nothing to claim");
        delete claimable[msg.sender];
        totalClaimable -= assets;
        usdc.safeTransfer(msg.sender, assets);
        emit Claimed(msg.sender, assets);
    }

    function _tradable(Market storage m) private view {
        require(!tradingPaused, "Trading paused");
        require(m.status == Status.Trading && block.timestamp < m.endTime - TRADING_CUTOFF, "Market closed");
    }

    function _payoff(Market storage m, uint256 price, uint256 contracts) private view returns (uint256) {
        uint256 difference = m.isCall
            ? (price > m.strikePrice ? price - m.strikePrice : 0)
            : (price < m.strikePrice ? m.strikePrice - price : 0);
        return Math.mulDiv(contracts, Math.min(difference, m.strikePrice), m.strikePrice);
    }

    function _receiveUSDC(uint256 assets) private {
        uint256 beforeBalance = usdc.balanceOf(address(this));
        usdc.safeTransferFrom(msg.sender, address(this), assets);
        require(usdc.balanceOf(address(this)) - beforeBalance == assets, "Unsupported transfer fee");
    }

    function _boundaryPrice(uint256 pairId, uint64 timestamp, bytes[] calldata data) private returns (uint256) {
        uint256 fee = pyth.getUpdateFee(data);
        require(msg.value == fee, "Incorrect Pyth fee");
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = pairs[pairId].priceId;
        PythStructs.PriceFeed[] memory feeds =
            pyth.parsePriceFeedUpdatesUnique{value: fee}(data, ids, timestamp, timestamp + ORACLE_WINDOW);
        require(feeds.length == 1 && feeds[0].id == ids[0], "Wrong feed");
        PythStructs.Price memory p = feeds[0].price;
        require(
            p.publishTime >= timestamp && p.publishTime <= timestamp + ORACLE_WINDOW
                && p.publishTime <= block.timestamp,
            "Invalid publish time"
        );
        return _normalizePrice(p);
    }

    function _currentPrice(Market storage m, bytes[] calldata data) private returns (uint256) {
        uint256 fee = pyth.getUpdateFee(data);
        require(msg.value == fee, "Incorrect Pyth fee");
        pyth.updatePriceFeeds{value: fee}(data);
        PythStructs.Price memory p = pyth.getPriceNoOlderThan(pairs[m.pairId].priceId, MAX_PRICE_AGE);
        require(
            p.publishTime >= m.startTime && p.publishTime <= block.timestamp
                && block.timestamp - p.publishTime <= MAX_PRICE_AGE,
            "Invalid publish time"
        );
        return _normalizePrice(p);
    }

    function _normalizePrice(PythStructs.Price memory p) private pure returns (uint256 price) {
        require(p.price > 0 && p.expo >= -18 && p.expo <= 0, "Invalid price");
        require(uint256(p.conf) * BPS <= uint256(uint64(p.price)) * MAX_CONFIDENCE_BPS, "Uncertain price");
        price = uint256(uint64(p.price)) * 10 ** uint32(int32(18) + p.expo);
        require(price <= MAX_PRICE, "Invalid price");
    }
}

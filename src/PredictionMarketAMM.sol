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
import {pmUSDC} from "./pmUSDC.sol";

/// @dev Pyth spot updates authenticate prices at the time the worker executes each lifecycle call.
interface IPredictionPyth {
    function getUpdateFee(bytes[] calldata data) external view returns (uint256);
    function updatePriceFeeds(bytes[] calldata data) external payable;
    function getPriceNoOlderThan(bytes32 id, uint256 age) external view returns (PythStructs.Price memory);
}

/// @notice Buy-only binary prediction vault. The vault is every bettor's counterparty.
/// @dev Cash and outcome balances have 6 decimals; balances are fixed USDC payouts on a win.
///      Price/time/volatility odds include a vault edge and actual USDC backs the worst payout.
///      This is a collateral hedge, not an external BTC/ETH/SOL derivatives hedge.
contract PredictionMarketAMM is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_UTILIZATION_BPS = 8_000;
    uint256 public constant MAX_CONFIDENCE_BPS = 100;
    uint64 public constant TRADING_CUTOFF = 5;
    uint256 public constant WAD = 1e18;
    uint256 public constant YEAR = 365 days;
    uint256 public constant MAX_PRICE_AGE = 5;
    uint256 public constant MAX_TRADERS_PER_MARKET = 128;
    uint256 public constant MIN_PROBABILITY = 1e16; // 1%, at most 100x before fees
    uint256 public constant MAX_PROBABILITY = 95e16;

    enum Status {
        Scheduled,
        Trading,
        Resolved
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
        uint64 duration;
        uint256 openingPrice; // USD, normalized to 18 decimals
        uint256 closingPrice;
        uint256 volatilityBps; // annualized volatility, fixed when created
        uint256 upOutstanding;
        uint256 downOutstanding;
        bool upWins; // equality is Up
    }

    IERC20 public immutable usdc;
    IPredictionPyth public immutable pyth;
    pmUSDC public immutable shareToken;
    uint256 public immutable feeBps;
    Pair[] public pairs;
    mapping(bytes32 => bool) private activeNames;
    mapping(bytes32 => bool) private activeFeeds;
    Market[] private markets;
    mapping(address => bool) public authorizedBackends;
    mapping(uint256 => mapping(address => uint256)) public upBalance;
    mapping(uint256 => mapping(address => uint256)) public downBalance;
    mapping(uint256 => address[]) public traders;
    uint256 public reservedPayout;
    uint256 public unresolvedExposureMarkets;
    uint256 public totalFees;
    bool public tradingPaused;

    event PairAdded(uint256 indexed pairId, string name, bytes32 priceId);
    event BackendAuthorized(address indexed backend, bool authorized);
    event PairRemoved(uint256 indexed pairId);
    event MarketCreated(uint256 indexed marketId, uint256 indexed pairId, uint64 duration, uint256 volatilityBps);
    event MarketOpened(uint256 indexed marketId, uint256 price, uint64 startTime, uint64 endTime);
    event MarketResolved(uint256 indexed marketId, uint256 price, bool upWins, uint256 liability);
    event Bought(
        uint256 indexed marketId,
        address indexed trader,
        bool up,
        uint256 assets,
        uint256 shares,
        uint256 fee,
        uint256 entryPrice
    );
    event Paid(uint256 indexed marketId, address indexed trader, uint256 assets);
    event Deposited(address indexed lp, uint256 assets, uint256 shares);
    event Withdrawn(address indexed lp, uint256 assets, uint256 shares);
    event TradingPaused(bool paused);

    modifier onlyOperator() {
        require(msg.sender == owner() || authorizedBackends[msg.sender], "Not authorized backend");
        _;
    }

    constructor(address usdc_, address pyth_, uint256 feeBps_) Ownable(msg.sender) {
        require(usdc_.code.length > 0 && pyth_.code.length > 0, "Invalid contract");
        require(IERC20Metadata(usdc_).decimals() == 6, "USDC must have 6 decimals");
        require(feeBps_ <= 500, "Fee exceeds 5%");
        usdc = IERC20(usdc_);
        pyth = IPredictionPyth(pyth_);
        feeBps = feeBps_;
        shareToken = new pmUSDC(address(this));
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

    /// @notice Total pair IDs ever assigned, including removed pairs. IDs are never reused.
    function pairCount() external view returns (uint256) {
        return pairs.length;
    }

    function priceIds(uint256 pairId) external view returns (bytes32) {
        return pairs[pairId].priceId;
    }

    function addPair(string calldata name, bytes32 priceId) external onlyOwner returns (uint256 pairId) {
        require(bytes(name).length > 0, "Invalid name");
        require(priceId != bytes32(0), "Invalid feed");
        bytes32 nameHash = keccak256(bytes(name));
        require(!activeNames[nameHash], "Duplicate pair");
        require(!activeFeeds[priceId], "Duplicate feed");
        activeNames[nameHash] = true;
        activeFeeds[priceId] = true;
        pairId = pairs.length;
        pairs.push(Pair(name, priceId, true));
        emit PairAdded(pairId, name, priceId);
    }

    /// @notice Disable new rounds without changing the oracle or lifecycle of existing rounds.
    function removePair(uint256 pairId) external onlyOwner {
        require(pairId < pairs.length, "Invalid pair");
        Pair storage pair = pairs[pairId];
        require(pair.active, "Pair inactive");
        pair.active = false;
        activeNames[keccak256(bytes(pair.name))] = false;
        activeFeeds[pair.priceId] = false;
        emit PairRemoved(pairId);
    }

    function setTradingPaused(bool paused) external onlyOwner {
        tradingPaused = paused;
        emit TradingPaused(paused);
    }

    function authorizeBackend(address backend, bool authorized) external onlyOwner {
        require(backend != address(0), "Invalid backend");
        authorizedBackends[backend] = authorized;
        emit BackendAuthorized(backend, authorized);
    }

    /// @notice Create a round that the backend can open at any time (volatility: 100-50,000 bps).
    function createMarket(uint256 pairId, uint64 duration, uint256 volatilityBps)
        external
        onlyOperator
        returns (uint256 id)
    {
        require(pairId < pairs.length, "Invalid pair");
        require(pairs[pairId].active, "Pair inactive");
        require(
            duration == 5 minutes || duration == 15 minutes || duration == 1 hours || duration == 1 days,
            "Invalid duration"
        );
        require(volatilityBps >= 100 && volatilityBps <= 50_000, "Invalid volatility");
        id = markets.length;
        markets.push(Market(pairId, Status.Scheduled, 0, 0, duration, 0, 0, volatilityBps, 0, 0, false));
        emit MarketCreated(id, pairId, duration, volatilityBps);
    }

    /// @notice Start the round now using a fresh signed Pyth update, without an opening window.
    function openMarket(uint256 id, bytes[] calldata data) external payable onlyOperator nonReentrant {
        Market storage m = markets[id];
        require(m.status == Status.Scheduled, "Not scheduled");
        m.openingPrice = _spotPrice(m.pairId, 0, data);
        m.startTime = uint64(block.timestamp);
        m.endTime = m.startTime + m.duration;
        m.status = Status.Trading;
        emit MarketOpened(id, m.openingPrice, m.startTime, m.endTime);
    }

    /// @notice Conservative equity while rounds are open; exact net assets after all rounds resolve.
    function vaultValue() public view returns (uint256) {
        return usdc.balanceOf(address(this)) - reservedPayout;
    }

    /// @dev Virtual asset/share prevents a zero-supply donation from being awarded to the next depositor.
    function previewDeposit(uint256 assets) public view returns (uint256) {
        return Math.mulDiv(assets, shareToken.totalSupply() + 1, vaultValue() + 1);
    }

    function previewRedeem(uint256 shares) public view returns (uint256) {
        return Math.mulDiv(shares, vaultValue() + 1, shareToken.totalSupply() + 1);
    }

    function deposit(uint256 assets, uint256 minShares) external nonReentrant returns (uint256 shares) {
        require(unresolvedExposureMarkets == 0, "Unresolved markets lock LPs");
        require(assets > 0, "Zero assets");
        shares = previewDeposit(assets);
        require(shares > 0 && shares >= minShares, "Share slippage");
        _receiveUSDC(assets);
        shareToken.mint(msg.sender, shares);
        emit Deposited(msg.sender, assets, shares);
    }

    function withdraw(uint256 shares, uint256 minAssets) external nonReentrant returns (uint256 assets) {
        require(unresolvedExposureMarkets == 0, "Unresolved markets lock LPs");
        require(shares > 0, "Zero shares");
        assets = previewRedeem(shares);
        require(assets > 0 && assets >= minAssets, "Asset slippage");
        shareToken.burn(msg.sender, shares);
        usdc.safeTransfer(msg.sender, assets);
        emit Withdrawn(msg.sender, assets, shares);
    }

    /// @notice Model probability using a symmetric rational sigmoid, not a calibrated forecast.
    /// @dev z = (spot/open - 1) / (annualVol * sqrt(secondsRemaining/YEAR)).
    ///      pUp = (1 + z/sqrt(1+z*z))/2. Prices use 18 decimals. Quote inputs are untrusted;
    ///      buy verifies the supplied spot against a fresh, signed Pyth update.
    function winProbability(uint256 id, bool up, uint256 currentPrice) public view returns (uint256 probability) {
        Market storage m = markets[id];
        _tradable(m);
        require(currentPrice > 0 && currentPrice <= uint256(uint64(type(int64).max)) * WAD, "Invalid price");
        uint256 timeScale = Math.sqrt(Math.mulDiv(m.endTime - block.timestamp, WAD * WAD, YEAR));
        uint256 horizonVol = Math.mulDiv(m.volatilityBps * 1e14, timeScale, WAD);
        uint256 difference =
            currentPrice >= m.openingPrice ? currentPrice - m.openingPrice : m.openingPrice - currentPrice;
        uint256 movement = Math.mulDiv(difference, WAD, m.openingPrice);
        // Saturation bounds intermediate arithmetic; such extreme odds are rejected below.
        uint256 z = Math.min(Math.mulDiv(movement, WAD, horizonVol), 10 * WAD);
        uint256 score = Math.mulDiv(z, WAD, Math.sqrt(WAD * WAD + z * z));
        uint256 upProbability = currentPrice >= m.openingPrice ? (WAD + score) / 2 : (WAD - score) / 2;
        probability = up ? upProbability : WAD - upProbability;
        require(probability >= MIN_PROBABILITY && probability <= MAX_PROBABILITY, "Odds outside limits");
    }

    /// @notice Fixed gross winning payout including returned stake. Multiplier = shares/assets.
    /// @dev Expected vault edge is feeBps if the model probability matches the actual probability.
    function quoteBuy(uint256 id, bool up, uint256 assets, uint256 currentPrice)
        public
        view
        returns (uint256 shares, uint256 fee)
    {
        uint256 probability = winProbability(id, up, currentPrice);
        fee = _fee(assets);
        require(assets > fee, "Trade too small");
        shares = Math.mulDiv(assets - fee, WAD, probability);
        require(shares > assets, "Trade too small");
    }

    function buy(
        uint256 id,
        bool up,
        uint256 assets,
        uint256 currentPrice,
        uint256 minShares,
        uint256 deadline,
        bytes[] calldata data
    ) external payable nonReentrant returns (uint256 shares) {
        require(block.timestamp <= deadline, "Deadline passed");
        require(shareToken.totalSupply() > 0, "No LP liquidity");
        Market storage m = markets[id];
        _tradable(m);
        uint256 price = _spotPrice(m.pairId, m.startTime, data);
        require(price == currentPrice, "Price mismatch");
        uint256 fee;
        (shares, fee) = quoteBuy(id, up, assets, price);
        require(shares > 0 && shares >= minShares, "Share slippage");
        if (upBalance[id][msg.sender] == 0 && downBalance[id][msg.sender] == 0) {
            require(traders[id].length < MAX_TRADERS_PER_MARKET, "Market participant limit");
            traders[id].push(msg.sender);
        }
        uint256 oldReserve = Math.max(m.upOutstanding, m.downOutstanding);
        if (up) {
            m.upOutstanding += shares;
            upBalance[id][msg.sender] += shares;
        } else {
            m.downOutstanding += shares;
            downBalance[id][msg.sender] += shares;
        }
        _updateReserve(m, oldReserve);
        _receiveUSDC(assets);
        require(
            reservedPayout <= Math.mulDiv(usdc.balanceOf(address(this)), MAX_UTILIZATION_BPS, BPS),
            "Vault utilization exceeded"
        );
        totalFees += fee;
        emit Bought(id, msg.sender, up, assets, shares, fee, price);
    }

    /// @notice Backend resolves after expiry using a fresh execution-time quote, even while paused.
    function resolveMarket(uint256 id, bytes[] calldata data) external payable onlyOperator nonReentrant {
        Market storage m = markets[id];
        require(m.status == Status.Trading && block.timestamp >= m.endTime, "Not resolvable");
        uint256 price = _spotPrice(m.pairId, m.endTime, data);
        m.closingPrice = price;
        m.upWins = price >= m.openingPrice;
        m.status = Status.Resolved;
        uint256 oldReserve = Math.max(m.upOutstanding, m.downOutstanding);
        uint256 liability = m.upWins ? m.upOutstanding : m.downOutstanding;
        reservedPayout -= oldReserve;
        if (oldReserve != 0) --unresolvedExposureMarkets;
        m.upOutstanding = 0;
        m.downOutstanding = 0;
        emit MarketResolved(id, price, m.upWins, liability);
        address[] storage holders = traders[id];
        for (uint256 i; i < holders.length; ++i) {
            address holder = holders[i];
            uint256 assets = m.upWins ? upBalance[id][holder] : downBalance[id][holder];
            upBalance[id][holder] = 0;
            downBalance[id][holder] = 0;
            if (assets != 0) usdc.safeTransfer(holder, assets);
            emit Paid(id, holder, assets);
        }
    }

    function _tradable(Market storage m) private view {
        require(!tradingPaused, "Trading paused");
        require(m.status == Status.Trading && block.timestamp < m.endTime - TRADING_CUTOFF, "Market closed");
    }

    function _fee(uint256 assets) private view returns (uint256) {
        return Math.mulDiv(assets, feeBps, BPS, Math.Rounding.Ceil);
    }

    function _updateReserve(Market storage m, uint256 oldReserve) private {
        uint256 next = Math.max(m.upOutstanding, m.downOutstanding);
        reservedPayout = reservedPayout - oldReserve + next;
        if (oldReserve == 0 && next != 0) ++unresolvedExposureMarkets;
        if (oldReserve != 0 && next == 0) --unresolvedExposureMarkets;
    }

    function _receiveUSDC(uint256 assets) private {
        uint256 beforeBalance = usdc.balanceOf(address(this));
        usdc.safeTransferFrom(msg.sender, address(this), assets);
        require(usdc.balanceOf(address(this)) - beforeBalance == assets, "Unsupported transfer fee");
    }

    function _spotPrice(uint256 pairId, uint64 minTime, bytes[] calldata data) private returns (uint256) {
        uint256 fee = pyth.getUpdateFee(data);
        require(msg.value == fee, "Incorrect Pyth fee");
        pyth.updatePriceFeeds{value: fee}(data);
        PythStructs.Price memory p = pyth.getPriceNoOlderThan(pairs[pairId].priceId, MAX_PRICE_AGE);
        require(
            p.publishTime >= minTime && p.publishTime <= block.timestamp
                && block.timestamp - p.publishTime <= MAX_PRICE_AGE,
            "Invalid publish time"
        );
        return _normalizePrice(p);
    }

    function _normalizePrice(PythStructs.Price memory p) private pure returns (uint256) {
        require(p.price > 0 && p.expo >= -18 && p.expo <= 0, "Invalid price");
        require(uint256(p.conf) * BPS <= uint256(uint64(p.price)) * MAX_CONFIDENCE_BPS, "Uncertain price");
        return uint256(uint64(p.price)) * 10 ** uint32(int32(18) + p.expo);
    }
}

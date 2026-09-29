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

/// @dev The pinned Pyth SDK predates this method. The deployed oracle MUST support it.
interface IPredictionPyth {
    function getUpdateFee(bytes[] calldata data) external view returns (uint256);
    function parsePriceFeedUpdatesUnique(bytes[] calldata data, bytes32[] calldata ids, uint64 minTime, uint64 maxTime)
        external payable returns (PythStructs.PriceFeed[] memory);
}

/// @notice Binary constant-product AMM. The USDC vault underwrites traders; pmUSDC owns vault P/L.
/// @dev Cash and outcome shares have 6 decimals; winning shares redeem 1:1 for USDC.
///      Virtual outcome inventories price trades; actual USDC backs the worst possible payout.
///      This is a collateral hedge, not an external BTC/ETH/SOL derivatives hedge.
contract PredictionMarketAMM is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_UTILIZATION_BPS = 8_000;
    uint256 public constant MAX_CONFIDENCE_BPS = 100;
    uint64 public constant ORACLE_WINDOW = 30;
    uint64 public constant TRADING_CUTOFF = 5;
    uint256 public constant MAX_INVENTORY = type(uint128).max;

    enum Status { Scheduled, Trading, Resolved }

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
        uint256 openingPrice; // USD, normalized to 18 decimals
        uint256 closingPrice;
        uint256 upPool;
        uint256 downPool;
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
    mapping(bytes32 => bool) public scheduled;
    mapping(uint256 => mapping(address => uint256)) public upBalance;
    mapping(uint256 => mapping(address => uint256)) public downBalance;
    uint256 public reservedPayout;
    uint256 public unresolvedExposureMarkets;
    uint256 public totalFees;
    bool public tradingPaused;

    event PairAdded(uint256 indexed pairId, string name, bytes32 priceId);
    event PairRemoved(uint256 indexed pairId);
    event MarketCreated(uint256 indexed marketId, uint256 indexed pairId, uint64 startTime, uint64 endTime, uint256 depth);
    event MarketOpened(uint256 indexed marketId, uint256 price);
    event MarketResolved(uint256 indexed marketId, uint256 price, bool upWins, uint256 liability);
    event Bought(uint256 indexed marketId, address indexed trader, bool up, uint256 assets, uint256 shares, uint256 fee);
    event Sold(uint256 indexed marketId, address indexed trader, bool up, uint256 shares, uint256 assets, uint256 fee);
    event Claimed(uint256 indexed marketId, address indexed trader, uint256 assets);
    event Deposited(address indexed lp, uint256 assets, uint256 shares);
    event Withdrawn(address indexed lp, uint256 assets, uint256 shares);
    event TradingPaused(bool paused);

    constructor(address usdc_, address pyth_, uint256 feeBps_) Ownable(msg.sender) {
        require(usdc_.code.length > 0 && pyth_.code.length > 0, "Invalid contract");
        require(IERC20Metadata(usdc_).decimals() == 6, "USDC must have 6 decimals");
        require(feeBps_ <= 500, "Fee exceeds 5%");
        usdc = IERC20(usdc_);
        pyth = IPredictionPyth(pyth_);
        feeBps = feeBps_;
        shareToken = new pmUSDC(address(this));
    }

    function marketCount() external view returns (uint256) { return markets.length; }
    function getMarket(uint256 id) external view returns (Market memory) { return markets[id]; }

    /// @notice Total pair IDs ever assigned, including removed pairs. IDs are never reused.
    function pairCount() external view returns (uint256) { return pairs.length; }
    function priceIds(uint256 pairId) external view returns (bytes32) { return pairs[pairId].priceId; }

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

    /// @notice Schedule one UTC-aligned round per asset/duration/start. Depth sets the initial 50/50 curve.
    function createMarket(uint256 pairId, uint64 duration, uint64 startTime, uint256 depth)
        external onlyOwner returns (uint256 id)
    {
        require(pairId < pairs.length, "Invalid pair");
        require(pairs[pairId].active, "Pair inactive");
        require(duration == 5 minutes || duration == 15 minutes || duration == 1 hours || duration == 1 days, "Invalid duration");
        require(startTime > block.timestamp && startTime % duration == 0, "Invalid start");
        require(depth > 0 && depth <= MAX_INVENTORY, "Invalid depth");
        bytes32 key = keccak256(abi.encode(pairId, duration, startTime));
        require(!scheduled[key], "Round exists");
        scheduled[key] = true;
        id = markets.length;
        markets.push(Market(pairId, Status.Scheduled, startTime, startTime + duration, 0, 0, depth, depth, 0, 0, false));
        emit MarketCreated(id, pairId, startTime, startTime + duration, depth);
    }

    /// @notice Anyone can open a scheduled market with the first Pyth update at/after its start.
    function openMarket(uint256 id, bytes[] calldata data) external payable nonReentrant {
        Market storage m = markets[id];
        require(m.status == Status.Scheduled, "Not scheduled");
        require(block.timestamp >= m.startTime && block.timestamp <= m.startTime + ORACLE_WINDOW, "Opening window closed");
        m.openingPrice = _boundaryPrice(m.pairId, m.startTime, data);
        m.status = Status.Trading;
        emit MarketOpened(id, m.openingPrice);
    }

    /// @notice Conservative equity while rounds are open; exact net assets after all rounds resolve.
    function vaultValue() public view returns (uint256) { return usdc.balanceOf(address(this)) - reservedPayout; }

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

    function quoteBuy(uint256 id, bool up, uint256 assets) public view returns (uint256 shares, uint256 fee) {
        Market storage m = markets[id];
        _tradable(m);
        fee = _fee(assets);
        require(assets > fee, "Trade too small");
        uint256 net = assets - fee;
        (uint256 chosen, uint256 other) = up ? (m.upPool, m.downPool) : (m.downPool, m.upPool);
        require(net <= MAX_INVENTORY - other && net <= MAX_INVENTORY - chosen, "Trade too large");
        uint256 next = Math.mulDiv(chosen, other, other + net, Math.Rounding.Ceil);
        shares = chosen + net - next;
    }

    function buy(uint256 id, bool up, uint256 assets, uint256 minShares, uint256 deadline)
        external nonReentrant returns (uint256 shares)
    {
        require(block.timestamp <= deadline, "Deadline passed");
        require(shareToken.totalSupply() > 0, "No LP liquidity");
        uint256 fee;
        (shares, fee) = quoteBuy(id, up, assets);
        require(shares > 0 && shares >= minShares, "Share slippage");
        Market storage m = markets[id];
        uint256 oldReserve = Math.max(m.upOutstanding, m.downOutstanding);
        uint256 net = assets - fee;
        if (up) {
            m.upPool = m.upPool + net - shares;
            m.downPool += net;
            m.upOutstanding += shares;
            upBalance[id][msg.sender] += shares;
        } else {
            m.downPool = m.downPool + net - shares;
            m.upPool += net;
            m.downOutstanding += shares;
            downBalance[id][msg.sender] += shares;
        }
        _updateReserve(m, oldReserve);
        _receiveUSDC(assets);
        require(reservedPayout <= Math.mulDiv(usdc.balanceOf(address(this)), MAX_UTILIZATION_BPS, BPS), "Vault utilization exceeded");
        totalFees += fee;
        emit Bought(id, msg.sender, up, assets, shares, fee);
    }

    /// @notice Quote shares needed to receive grossAssets less the trading fee.
    function quoteSell(uint256 id, bool up, uint256 grossAssets) public view returns (uint256 shares, uint256 assets, uint256 fee) {
        Market storage m = markets[id];
        _tradable(m);
        fee = _fee(grossAssets);
        require(grossAssets > fee, "Trade too small");
        assets = grossAssets - fee;
        (uint256 chosen, uint256 other) = up ? (m.upPool, m.downPool) : (m.downPool, m.upPool);
        require(grossAssets < other, "Insufficient pool");
        uint256 next = Math.mulDiv(chosen, other, other - grossAssets, Math.Rounding.Ceil);
        require(next <= MAX_INVENTORY, "Trade too large");
        shares = grossAssets + next - chosen;
    }

    function sell(uint256 id, bool up, uint256 grossAssets, uint256 maxShares, uint256 deadline)
        external nonReentrant returns (uint256 shares, uint256 assets)
    {
        require(block.timestamp <= deadline, "Deadline passed");
        uint256 fee;
        (shares, assets, fee) = quoteSell(id, up, grossAssets);
        require(shares <= maxShares, "Share slippage");
        Market storage m = markets[id];
        uint256 oldReserve = Math.max(m.upOutstanding, m.downOutstanding);
        if (up) {
            require(upBalance[id][msg.sender] >= shares, "Insufficient shares");
            upBalance[id][msg.sender] -= shares;
            m.upOutstanding -= shares;
            m.upPool = m.upPool + shares - grossAssets;
            m.downPool -= grossAssets;
        } else {
            require(downBalance[id][msg.sender] >= shares, "Insufficient shares");
            downBalance[id][msg.sender] -= shares;
            m.downOutstanding -= shares;
            m.downPool = m.downPool + shares - grossAssets;
            m.upPool -= grossAssets;
        }
        _updateReserve(m, oldReserve);
        require(usdc.balanceOf(address(this)) >= reservedPayout + assets, "Insufficient collateral");
        totalFees += fee;
        usdc.safeTransfer(msg.sender, assets);
        emit Sold(id, msg.sender, up, shares, assets, fee);
    }

    /// @notice Resolve once for all holders, even while trading is paused. No settlement deadline.
    function resolveMarket(uint256 id, bytes[] calldata data) external payable nonReentrant {
        Market storage m = markets[id];
        require(m.status == Status.Trading && block.timestamp >= m.endTime, "Not resolvable");
        uint256 price = _boundaryPrice(m.pairId, m.endTime, data);
        m.closingPrice = price;
        m.upWins = price >= m.openingPrice;
        m.status = Status.Resolved;
        uint256 oldReserve = Math.max(m.upOutstanding, m.downOutstanding);
        uint256 liability = m.upWins ? m.upOutstanding : m.downOutstanding;
        reservedPayout = reservedPayout - oldReserve + liability;
        if (oldReserve != 0) --unresolvedExposureMarkets;
        emit MarketResolved(id, price, m.upWins, liability);
    }

    /// @notice Anyone may submit a claim; USDC always goes to the holder. Losing balances are cleared too.
    function claim(uint256 id, address holder) external nonReentrant returns (uint256 assets) {
        Market storage m = markets[id];
        require(m.status == Status.Resolved, "Not resolved");
        uint256 up = upBalance[id][holder];
        uint256 down = downBalance[id][holder];
        require(up != 0 || down != 0, "Nothing to claim");
        upBalance[id][holder] = 0;
        downBalance[id][holder] = 0;
        m.upOutstanding -= up;
        m.downOutstanding -= down;
        assets = m.upWins ? up : down;
        reservedPayout -= assets;
        if (assets != 0) usdc.safeTransfer(holder, assets);
        emit Claimed(id, holder, assets);
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

    function _boundaryPrice(uint256 pairId, uint64 timestamp, bytes[] calldata data) private returns (uint256) {
        uint256 fee = pyth.getUpdateFee(data);
        require(msg.value == fee, "Incorrect Pyth fee");
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = pairs[pairId].priceId;
        PythStructs.PriceFeed[] memory feeds = pyth.parsePriceFeedUpdatesUnique{value: fee}(data, ids, timestamp, timestamp + ORACLE_WINDOW);
        require(feeds.length == 1 && feeds[0].id == ids[0], "Wrong feed");
        PythStructs.Price memory p = feeds[0].price;
        require(p.publishTime >= timestamp && p.publishTime <= timestamp + ORACLE_WINDOW && p.publishTime <= block.timestamp, "Invalid publish time");
        require(p.price > 0 && p.expo >= -18 && p.expo <= 0, "Invalid price");
        require(uint256(p.conf) * BPS <= uint256(uint64(p.price)) * MAX_CONFIDENCE_BPS, "Uncertain price");
        return uint256(uint64(p.price)) * 10 ** uint32(int32(18) + p.expo);
    }
}

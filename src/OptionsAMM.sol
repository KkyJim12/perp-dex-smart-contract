// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "lib/pyth-sdk-solidity/IPyth.sol";
import "lib/pyth-sdk-solidity/PythStructs.sol";

interface IOpUSDC {
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

/// @title OptionsAMM
/// @notice Cash-settled European option AMM where the USDC LP vault is every buyer's counterparty.
/// @dev `contracts` and all cash values use USDC's native decimals. Strike and settlement prices use
///      the raw Pyth feed units, so a market's strike must be configured for its feed's exponent.
contract OptionsAMM {
    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_UTILIZATION_BPS = 8_000;

    ERC20 public immutable usdc;
    IPyth public immutable pyth;
    IOpUSDC public immutable opUSDC;
    address public owner;
    uint256 private unlocked = 1;

    struct Market {
        bytes32 priceId;
        uint256 strikePrice;
        uint256 expiry;
        uint256 premiumBps;
        bool isCall;
        bool active;
    }

    struct OptionPosition {
        uint256 marketId;
        uint256 contracts;
        uint256 premiumPaid;
        bool settled;
    }

    Market[] public markets;
    mapping(address => OptionPosition[]) public positions;
    uint256 public reservedPayout; // maximum aggregate payout owed to open options
    uint256 public vaultPremiums;
    uint256 public vaultPayouts;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event MarketCreated(uint256 indexed marketId, bytes32 indexed priceId, uint256 strikePrice, uint256 expiry, bool isCall, uint256 premiumBps);
    event MarketStatus(uint256 indexed marketId, bool active);
    event LPDeposited(address indexed lp, uint256 assets, uint256 shares);
    event LPWithdrawn(address indexed lp, uint256 assets, uint256 shares);
    event OptionBought(address indexed buyer, uint256 indexed positionId, uint256 indexed marketId, uint256 contracts, uint256 premium);
    event OptionSettled(address indexed buyer, uint256 indexed positionId, uint256 settlementPrice, uint256 payout);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier nonReentrant() {
        require(unlocked == 1, "Reentrant call");
        unlocked = 2;
        _;
        unlocked = 1;
    }

    constructor(address usdc_, address pyth_, address opUSDC_) {
        require(usdc_ != address(0) && pyth_ != address(0) && opUSDC_ != address(0), "Invalid address");
        usdc = ERC20(usdc_);
        pyth = IPyth(pyth_);
        opUSDC = IOpUSDC(opUSDC_);
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function createMarket(bytes32 priceId, uint256 strikePrice, uint256 expiry, uint256 premiumBps, bool isCall) external onlyOwner returns (uint256 marketId) {
        require(priceId != bytes32(0) && strikePrice > 0, "Invalid market");
        require(expiry > block.timestamp, "Expiry must be future");
        require(premiumBps > 0 && premiumBps <= BPS, "Invalid premium");
        marketId = markets.length;
        markets.push(Market(priceId, strikePrice, expiry, premiumBps, isCall, true));
        emit MarketCreated(marketId, priceId, strikePrice, expiry, isCall, premiumBps);
    }

    function setMarketActive(uint256 marketId, bool active) external onlyOwner {
        require(marketId < markets.length, "Market not found");
        markets[marketId].active = active;
        emit MarketStatus(marketId, active);
    }

    /// @notice Net asset value available to opUSDC holders after all maximum option obligations.
    function vaultValue() public view returns (uint256) {
        uint256 assets = usdc.balanceOf(address(this));
        return assets > reservedPayout ? assets - reservedPayout : 0;
    }

    function availableLiquidity() external view returns (uint256) {
        return vaultValue();
    }

    function lpShareValue(address lp) external view returns (uint256) {
        uint256 supply = opUSDC.totalSupply();
        return supply == 0 ? 0 : (opUSDC.balanceOf(lp) * vaultValue()) / supply;
    }

    function quotePremium(uint256 marketId, uint256 contracts) public view returns (uint256) {
        require(marketId < markets.length && contracts > 0, "Invalid quote");
        return (contracts * markets[marketId].premiumBps) / BPS;
    }

    function deposit(uint256 assets) external nonReentrant returns (uint256 shares) {
        require(assets > 0, "Zero assets");
        // The reserve's eventual unused amount belongs to the LP set that
        // underwrote the options, so do not admit a new LP mid-expiry.
        require(reservedPayout == 0, "Liquidity locked by open options");
        uint256 valueBefore = vaultValue();
        uint256 supply = opUSDC.totalSupply();
        shares = supply == 0 ? assets : (assets * supply) / valueBefore;
        require(shares > 0, "Zero shares");
        require(usdc.transferFrom(msg.sender, address(this), assets), "Transfer failed");
        opUSDC.mint(msg.sender, shares);
        emit LPDeposited(msg.sender, assets, shares);
    }

    function withdraw(uint256 shares) external nonReentrant returns (uint256 assets) {
        require(shares > 0 && shares <= opUSDC.balanceOf(msg.sender), "Invalid shares");
        // A reserve is a maximum, not a realized loss. Redeeming shares while it
        // exists would make the last remaining share owner capture any unused
        // reserve after settlement. Locking LP liquidity is the conservative
        // and economically fair choice until all option obligations are closed.
        require(reservedPayout == 0, "Liquidity locked by open options");
        uint256 supply = opUSDC.totalSupply();
        assets = (shares * vaultValue()) / supply;
        require(assets > 0, "Zero assets");
        opUSDC.burn(msg.sender, shares);
        require(usdc.transfer(msg.sender, assets), "Transfer failed");
        emit LPWithdrawn(msg.sender, assets, shares);
    }

    /// @notice Buy a fully collateralized long option. The vault takes the short/counterparty side.
    /// @param maxPremium Slippage limit that protects the buyer if the owner reprices before inclusion.
    function buyOption(uint256 marketId, uint256 contracts, uint256 maxPremium) external nonReentrant returns (uint256 positionId) {
        require(marketId < markets.length && contracts > 0, "Invalid option");
        Market storage market = markets[marketId];
        require(market.active && block.timestamp < market.expiry, "Market unavailable");
        uint256 premium = quotePremium(marketId, contracts);
        require(premium <= maxPremium, "Premium exceeds limit");
        require(premium > 0, "Premium too small");

        // The intrinsic payoff is capped at the contract notional (100%); reserve it before sale.
        // This makes each option fully collateralized even if every buyer exercises in the money.
        uint256 newReserved = reservedPayout + contracts;
        require(newReserved <= (usdc.balanceOf(address(this)) * MAX_UTILIZATION_BPS) / BPS, "Vault utilization exceeded");
        require(usdc.transferFrom(msg.sender, address(this), premium), "Transfer failed");
        reservedPayout = newReserved;
        vaultPremiums += premium;
        positionId = positions[msg.sender].length;
        positions[msg.sender].push(OptionPosition(marketId, contracts, premium, false));
        emit OptionBought(msg.sender, positionId, marketId, contracts, premium);
    }

    /// @notice Settle after expiry using a Pyth update supplied by the caller; anybody may settle.
    function settleOption(address buyer, uint256 positionId, bytes[] calldata priceUpdateData) external payable nonReentrant returns (uint256 payout) {
        require(positionId < positions[buyer].length, "Position not found");
        OptionPosition storage position = positions[buyer][positionId];
        require(!position.settled, "Already settled");
        Market storage market = markets[position.marketId];
        require(block.timestamp >= market.expiry, "Not expired");
        uint256 fee = pyth.getUpdateFee(priceUpdateData);
        require(msg.value == fee, "Incorrect Pyth fee");
        pyth.updatePriceFeeds{value: fee}(priceUpdateData);
        PythStructs.Price memory price = pyth.getPrice(market.priceId);
        require(price.price > 0 && price.publishTime >= market.expiry, "Invalid settlement price");
        uint256 settlementPrice = uint256(uint64(price.price));

        uint256 intrinsic = market.isCall
            ? (settlementPrice > market.strikePrice ? settlementPrice - market.strikePrice : 0)
            : (settlementPrice < market.strikePrice ? market.strikePrice - settlementPrice : 0);
        payout = (position.contracts * intrinsic) / market.strikePrice;
        if (payout > position.contracts) payout = position.contracts;

        position.settled = true;
        reservedPayout -= position.contracts;
        vaultPayouts += payout;
        if (payout > 0) require(usdc.transfer(buyer, payout), "Transfer failed");
        emit OptionSettled(buyer, positionId, settlementPrice, payout);
    }
}

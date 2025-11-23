// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "lib/pyth-sdk-solidity/IPyth.sol";
import "lib/pyth-sdk-solidity/PythStructs.sol";

contract PerpDEXPublic is ReentrancyGuard {
    using SafeERC20 for ERC20;

    // ---------- Core Addresses ----------
    IPyth public immutable pyth;
    ERC20 public immutable usdt;
    address public owner;
    address public relayer;        // off-chain engine / relayer
    address public privateEngine;  // FHE contract (Zama)

    // ---------- Constants ----------
    uint256 public constant ONE = 1e18;
    uint256 public constant FEE_RATIO = 5e14; // 0.05%
    uint256 public constant MAINTENANCE_MARGIN_RATIO = 10e16; // 10%
    uint256 public constant LIQUIDATION_REWARD_RATIO = 2e16; // 2%

    uint256 public constant SHARE_SCALE = 1e18;
    uint8 public immutable usdtDecimals;

    // ---------- LP Pool ----------
    uint256 public totalStaked;     // RAW USDT UNITS (e.g. 6 decimals)
    uint256 public totalShares;     // 1e18 precision
    mapping(address => uint256) public shares;

    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event PoolUpdated(uint256 totalStaked, string reason, int256 pnlImpact);

    // Helper: user LP value
    function stakeValueOf(address user) external view returns (uint256) {
        if (totalShares == 0) return 0;
        return (shares[user] * totalStaked) / totalShares;
    }

    // ---------- Pairs ----------
    struct PairInfo {
        string name;
        bytes32 pythTokenId;
        bool active;
    }

    mapping(string => PairInfo) public pairInfo;
    PairInfo[] public allPairs;

    // ---------- Username (optional UI nicety) ----------
    mapping(address => string) public usernames;
    mapping(string => address) public usernameToAddress;

    event UsernameRegistered(address indexed user, string username);
    event UsernameChanged(address indexed user, string oldUsername, string newUsername);

    // ---------- Relayer / Engine Events ----------
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);
    event RelayerSet(address indexed oldRelayer, address indexed newRelayer);
    event PrivateEngineSet(address indexed oldEngine, address indexed newEngine);

    // Margin & settlement events (no sensitive params)
    event MarginLocked(
        address indexed user,
        bytes32 indexed positionId,
        string pairs,
        uint256 margin,
        uint256 fees
    );

    event PositionSettled(
        address indexed user,
        bytes32 indexed positionId,
        int256 pnl,
        uint256 payout,
        uint256 closeFee,
        string reason // "CLOSE", "TP", "SL", "LIQ"
    );

    // ---------- Modifiers ----------
    modifier onlyOwner() {
        require(msg.sender == owner, "Not admin");
        _;
    }

    modifier onlyRelayer() {
        require(msg.sender == relayer, "Not relayer");
        _;
    }

    constructor(address _usdt, address _pyth) {
        require(_usdt != address(0) && _pyth != address(0), "Invalid address");
        usdt = ERC20(_usdt);
        pyth = IPyth(_pyth);
        owner = msg.sender;
        usdtDecimals = ERC20(_usdt).decimals();

        emit OwnershipTransferred(address(0), msg.sender);
        _addInitialPairs();
    }

    // ---------- Admin ----------
    function setRelayer(address _relayer) external onlyOwner {
        emit RelayerSet(relayer, _relayer);
        relayer = _relayer;
    }

    function setPrivateEngine(address _engine) external onlyOwner {
        emit PrivateEngineSet(privateEngine, _engine);
        privateEngine = _engine;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero owner");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // ---------- Username ----------
    function registerUsername(string calldata name) external {
        require(bytes(name).length >= 3 && bytes(name).length <= 32, "Bad length");
        require(bytes(usernames[msg.sender]).length == 0, "Already registered");
        require(usernameToAddress[name] == address(0), "Name taken");

        usernames[msg.sender] = name;
        usernameToAddress[name] = msg.sender;
        emit UsernameRegistered(msg.sender, name);
    }

    function changeUsername(string calldata newName) external {
        string memory current = usernames[msg.sender];
        require(bytes(current).length > 0, "Not registered");
        require(bytes(newName).length >= 3 && bytes(newName).length <= 32, "Bad length");
        require(usernameToAddress[newName] == address(0), "Name taken");

        delete usernameToAddress[current];
        usernames[msg.sender] = newName;
        usernameToAddress[newName] = msg.sender;
        emit UsernameChanged(msg.sender, current, newName);
    }

    // ---------- Pair Management ----------
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

    function addPairInternal(string memory pairs, bytes32 pythTokenId) internal {
        pairInfo[pairs] = PairInfo(pairs, pythTokenId, true);
        allPairs.push(pairInfo[pairs]);
    }

    function setPairActive(string calldata pairs, bool active) external onlyOwner {
        PairInfo storage info = pairInfo[pairs];
        require(bytes(info.name).length != 0, "Pair missing");
        info.active = active;
    }

    // ---------- Staking (LP Shares) ----------
    function stake(uint256 amount) external nonReentrant {
        require(amount > 0, "Zero amount");
        usdt.safeTransferFrom(msg.sender, address(this), amount);

        uint256 mintShares;
        if (totalStaked == 0 || totalShares == 0) {
            mintShares = amount * SHARE_SCALE;
        } else {
            mintShares = (amount * totalShares) / totalStaked;
        }

        require(mintShares > 0, "Amount too small");

        totalStaked += amount;
        totalShares += mintShares;
        shares[msg.sender] += mintShares;

        emit Staked(msg.sender, amount);
    }

    function unstake(uint256 shareAmount) external nonReentrant {
        require(shareAmount > 0, "Zero shares");
        require(shares[msg.sender] >= shareAmount, "Not enough shares");
        require(totalShares > 0, "No shares");

        uint256 amountOut = (shareAmount * totalStaked) / totalShares;

        shares[msg.sender] -= shareAmount;
        totalShares -= shareAmount;
        totalStaked -= amountOut;

        usdt.safeTransfer(msg.sender, amountOut);

        emit Unstaked(msg.sender, amountOut);
    }

    // ---------- Pool PnL Logic ----------
    function _applyPnLToPool(int256 pnl) internal {
        if (pnl > 0) {
            uint256 loss = uint256(pnl);
            require(totalStaked >= loss, "Pool depleted");
            totalStaked -= loss;
            emit PoolUpdated(totalStaked, "TraderWin", pnl);
        } else if (pnl < 0) {
            uint256 gain = uint256(-pnl);
            totalStaked += gain;
            emit PoolUpdated(totalStaked, "TraderLoss", pnl);
        }
    }

    // ---------- Relayed Position Lifecycle ----------
    /**
     * @notice Called by relayer when opening a position.
     * @dev
     *  - Pulls margin from user (user must approve this contract).
     *  - `fees` is computed off-chain by relayer (you can re-check limits here).
     *  - FHE engine will store encrypted position data.
     */
    function lockMarginForPosition(
        address user,
        string calldata pairs,
        bytes32 positionId,
        uint256 margin,
        uint256 fees
    ) external onlyRelayer nonReentrant {
        require(margin > 0, "Zero margin");
        require(fees <= margin, "Bad fee");
        PairInfo storage info = pairInfo[pairs];
        require(info.active, "Pair inactive");

        // Pull funds from user
        usdt.safeTransferFrom(user, address(this), margin);

        uint256 netMargin = margin - fees;
        // All USDT remains inside contract; pool mechanics handled via PnL routing

        emit MarginLocked(user, positionId, pairs, netMargin, fees);
        // NOTE: relayer must separately call FHE private engine to store encrypted pos
    }

    /**
     * @notice Called by relayer when closing / liquidating / TP/SL a position.
     * @dev
     *  - `pnl` is trader PnL in RAW USDT units (positive if trader wins).
     *  - `payout` is net USDT sent to trader (after fees).
     *  - `closeFee` is fee amount charged (optional, off-chain computed).
     *  - `reason` is a lightweight string: "CLOSE", "TP", "SL", "LIQ".
     *
     *  In a fully trust-minimized design, `pnl/payout` must be proven via zk.
     *  For now, we trust the relayer.
     */
    function settlePosition(
        address user,
        bytes32 positionId,
        int256 pnl,
        uint256 payout,
        uint256 closeFee,
        string calldata reason
    ) external onlyRelayer nonReentrant {
        // Apply PnL to LP pool
        _applyPnLToPool(pnl);

        // Pay trader
        if (payout > 0) {
            usdt.safeTransfer(user, payout);
        }

        emit PositionSettled(user, positionId, pnl, payout, closeFee, reason);
        // NOTE: relayer must also update FHE engine to mark position closed.
    }

    // ---------- Oracle Helper ----------
    function getPairOraclePrice1e8(string calldata pairs) external view returns (uint256) {
        PairInfo storage info = pairInfo[pairs];
        require(info.active, "Pair inactive");

        PythStructs.Price memory token = pyth.getPrice(info.pythTokenId);
        require(token.price > 0, "Bad price");

        int256 v = int256(token.price);
        int32 expo = token.expo;
        int32 diff = -8 - expo;
        if (diff > 0) {
            for (int32 i; i < diff; i++) v *= 10;
        } else if (diff < 0) {
            for (int32 i; i < -diff; i++) v /= 10;
        }
        return uint256(v);
    }
}

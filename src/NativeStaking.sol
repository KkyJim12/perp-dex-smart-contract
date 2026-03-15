// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

/**
 * @title NativeStaking
 * @notice Stake native tokens (KUB/MON) to earn waitlist points.
 *         Points = stakedAmount * 10 * minutesStaked (per snapshot).
 *         Unstaking has a 3-day cooldown and earns no points during cooldown.
 */
contract NativeStaking is Ownable, ReentrancyGuard {

    // ============================================================
    // CONSTANTS
    // ============================================================

    uint256 public constant UNSTAKE_COOLDOWN = 3 days;
    uint256 public constant POINTS_MULTIPLIER = 10;

    // ============================================================
    // STRUCTS
    // ============================================================

    struct StakeInfo {
        uint256 amount;              // Currently staked amount
        uint256 lastSnapshotTime;    // Last time points were calculated
        uint256 unstakeRequestTime;  // When unstake was requested (0 = not requested)
        uint256 unstakeAmount;       // Amount pending unstake
    }

    // ============================================================
    // STATE
    // ============================================================

    mapping(address => StakeInfo) public stakes;
    mapping(address => uint256) public points;

    address[] public stakers;
    mapping(address => bool) public isStaker;

    mapping(address => bool) public authorizedBackends;

    uint256 public totalStaked;
    uint256 public lastGlobalSnapshotTime;

    // ============================================================
    // EVENTS
    // ============================================================

    event Staked(address indexed user, uint256 amount, uint256 totalStaked);
    event UnstakeRequested(address indexed user, uint256 amount, uint256 claimableAt);
    event Unstaked(address indexed user, uint256 amount);
    event PointsAwarded(address indexed user, uint256 pointsEarned, uint256 totalPoints);
    event SnapshotCompleted(uint256 timestamp, uint256 totalStakers);
    event BackendAuthorized(address indexed backend, bool authorized);

    // ============================================================
    // MODIFIERS
    // ============================================================

    modifier onlyAuthorized() {
        require(
            msg.sender == owner() || authorizedBackends[msg.sender],
            "Not authorized"
        );
        _;
    }

    // ============================================================
    // CONSTRUCTOR
    // ============================================================

    constructor() Ownable(msg.sender) {
        lastGlobalSnapshotTime = block.timestamp;
    }

    // ============================================================
    // ADMIN
    // ============================================================

    function authorizeBackend(address _backend, bool _authorized) external onlyOwner {
        authorizedBackends[_backend] = _authorized;
        emit BackendAuthorized(_backend, _authorized);
    }

    // ============================================================
    // STAKING
    // ============================================================

    /// @notice Stake native tokens (KUB/MON)
    function stake() external payable nonReentrant {
        require(msg.value > 0, "Must stake > 0");

        StakeInfo storage info = stakes[msg.sender];

        // Track staker for snapshot iteration
        if (!isStaker[msg.sender]) {
            isStaker[msg.sender] = true;
            stakers.push(msg.sender);
            info.lastSnapshotTime = block.timestamp;
        }

        info.amount += msg.value;
        totalStaked += msg.value;

        emit Staked(msg.sender, msg.value, info.amount);
    }

    // ============================================================
    // UNSTAKING (3-day cooldown)
    // ============================================================

    /// @notice Request unstake - starts 3-day cooldown, stops earning points on unstaked amount
    function requestUnstake(uint256 _amount) external nonReentrant {
        StakeInfo storage info = stakes[msg.sender];
        require(info.amount >= _amount, "Insufficient staked");
        require(_amount > 0, "Must unstake > 0");
        require(info.unstakeAmount == 0, "Pending unstake exists");

        // Move from staked to pending unstake
        info.amount -= _amount;
        info.unstakeAmount = _amount;
        info.unstakeRequestTime = block.timestamp;
        totalStaked -= _amount;

        emit UnstakeRequested(msg.sender, _amount, block.timestamp + UNSTAKE_COOLDOWN);
    }

    /// @notice Claim unstaked tokens after cooldown
    function claimUnstake() external nonReentrant {
        StakeInfo storage info = stakes[msg.sender];
        require(info.unstakeAmount > 0, "No pending unstake");
        require(
            block.timestamp >= info.unstakeRequestTime + UNSTAKE_COOLDOWN,
            "Cooldown not finished"
        );

        uint256 amount = info.unstakeAmount;
        info.unstakeAmount = 0;
        info.unstakeRequestTime = 0;

        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "Transfer failed");

        emit Unstaked(msg.sender, amount);
    }

    // ============================================================
    // SNAPSHOT (admin/backend)
    // ============================================================

    /// @notice Take snapshot - calculates points for all stakers
    function snapshot() external onlyAuthorized {
        uint256 len = stakers.length;
        for (uint256 i = 0; i < len; ) {
            address user = stakers[i];
            if (stakes[user].amount > 0) {
                _calculatePoints(user);
            }
            unchecked { ++i; }
        }
        lastGlobalSnapshotTime = block.timestamp;
        emit SnapshotCompleted(block.timestamp, len);
    }

    /// @notice Take snapshot for a batch of stakers (gas-efficient for large staker sets)
    function snapshotBatch(uint256 _start, uint256 _end) external onlyAuthorized {
        uint256 len = stakers.length;
        if (_end > len) _end = len;
        require(_start < _end, "Invalid range");

        for (uint256 i = _start; i < _end; ) {
            address user = stakers[i];
            if (stakes[user].amount > 0) {
                _calculatePoints(user);
            }
            unchecked { ++i; }
        }
        lastGlobalSnapshotTime = block.timestamp;
        emit SnapshotCompleted(block.timestamp, _end - _start);
    }

    // ============================================================
    // INTERNAL
    // ============================================================

    /// @notice Calculate and award points: stakedAmount * 10 * minutesStaked
    function _calculatePoints(address _user) internal {
        StakeInfo storage info = stakes[_user];
        if (info.amount == 0 || info.lastSnapshotTime == 0) return;

        uint256 elapsed = block.timestamp - info.lastSnapshotTime;
        uint256 minutes_ = elapsed / 60;

        if (minutes_ > 0) {
            // points = (staked amount in wei) * 10 * minutes
            // Normalize to 18 decimals: divide by 1e18 to get token-based points
            uint256 earned = (info.amount * POINTS_MULTIPLIER * minutes_) / 1e18;
            if (earned > 0) {
                points[_user] += earned;
                emit PointsAwarded(_user, earned, points[_user]);
            }
        }

        info.lastSnapshotTime = block.timestamp;
    }

    // ============================================================
    // VIEW FUNCTIONS
    // ============================================================

    /// @notice Get user's pending (unclaimed) points since last snapshot
    function getPendingPoints(address _user) external view returns (uint256) {
        StakeInfo memory info = stakes[_user];
        if (info.amount == 0 || info.lastSnapshotTime == 0) return 0;

        uint256 elapsed = block.timestamp - info.lastSnapshotTime;
        uint256 minutes_ = elapsed / 60;
        return (info.amount * POINTS_MULTIPLIER * minutes_) / 1e18;
    }

    /// @notice Get total points (confirmed + pending)
    function getTotalPoints(address _user) external view returns (uint256) {
        StakeInfo memory info = stakes[_user];
        uint256 pending = 0;
        if (info.amount > 0 && info.lastSnapshotTime > 0) {
            uint256 elapsed = block.timestamp - info.lastSnapshotTime;
            uint256 minutes_ = elapsed / 60;
            pending = (info.amount * POINTS_MULTIPLIER * minutes_) / 1e18;
        }
        return points[_user] + pending;
    }

    /// @notice Get full user info
    function getUserInfo(address _user) external view returns (
        uint256 stakedAmount,
        uint256 pendingUnstake,
        uint256 unstakeClaimableAt,
        uint256 confirmedPoints,
        uint256 pendingPoints,
        bool canClaimUnstake
    ) {
        StakeInfo memory info = stakes[_user];
        stakedAmount = info.amount;
        pendingUnstake = info.unstakeAmount;
        confirmedPoints = points[_user];

        if (info.unstakeRequestTime > 0) {
            unstakeClaimableAt = info.unstakeRequestTime + UNSTAKE_COOLDOWN;
            canClaimUnstake = block.timestamp >= unstakeClaimableAt;
        }

        if (info.amount > 0 && info.lastSnapshotTime > 0) {
            uint256 elapsed = block.timestamp - info.lastSnapshotTime;
            uint256 minutes_ = elapsed / 60;
            pendingPoints = (info.amount * POINTS_MULTIPLIER * minutes_) / 1e18;
        }
    }

    /// @notice Get total number of stakers
    function getStakerCount() external view returns (uint256) {
        return stakers.length;
    }

    /// @notice Get staker address by index
    function getStaker(uint256 _index) external view returns (address) {
        return stakers[_index];
    }

    /// @notice Get contract's native token balance
    function getContractBalance() external view returns (uint256) {
        return address(this).balance;
    }

    // Allow contract to receive native tokens
    receive() external payable {}
}

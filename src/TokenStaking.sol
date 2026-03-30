// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title TokenStaking
 * @notice GUGUToken staking contract — stake GUGU to earn GUGU rewards
 *
 *         Features:
 *         - Admin-adjustable annual interest rate (APR)
 *         - Flexible staking: stake / unstake anytime
 *         - Claim or compound accumulated rewards
 *         - Optional minimum lock period
 *         - Emergency withdraw (forfeits unclaimed rewards)
 *         - Pause/unpause by owner
 *
 *         Reward model:
 *         Rewards are distributed from a pre-funded reward pool held by this contract.
 *         reward = stakedAmount × APR × elapsedTime / (365 days × 10000)
 *         APR is stored in basis points (e.g. 1000 = 10%).
 */
contract TokenStaking is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════
    //                  State
    // ═══════════════════════════════════════════

    IERC20 public immutable guguToken;

    /// @notice Annual Percentage Rate in basis points (100 = 1%, 1000 = 10%)
    uint256 public aprBps;

    /// @notice Maximum APR cap in basis points (default 50% = 5000)
    uint256 public constant MAX_APR_BPS = 5000;

    /// @notice Minimum lock duration before unstake is allowed (0 = no lock)
    uint256 public minLockDuration;

    /// @notice Contract paused flag
    bool public paused;

    /// @notice Total GUGU tokens staked across all users
    uint256 public totalStaked;

    /// @notice Per-user staking information
    struct StakeInfo {
        uint256 amount;          // staked principal
        uint256 rewardDebt;      // accumulated but unclaimed rewards
        uint256 lastUpdateTime;  // last time rewards were calculated
        uint256 stakedAt;        // timestamp of first stake (for lock check)
        uint256 lastAprBps;      // APR snapshot at last update (prevents retroactive APR changes)
    }

    mapping(address => StakeInfo) public stakes;

    // ── Events ──
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount, uint256 reward);
    event RewardsClaimed(address indexed user, uint256 reward);
    event RewardsCompounded(address indexed user, uint256 reward);
    event AprUpdated(uint256 oldApr, uint256 newApr);
    event MinLockDurationUpdated(uint256 oldDuration, uint256 newDuration);
    event Paused(address indexed account);
    event Unpaused(address indexed account);
    event EmergencyWithdraw(address indexed user, uint256 amount);
    event RewardPoolFunded(address indexed funder, uint256 amount);
    event RewardPoolDrained(address indexed to, uint256 amount);

    // ── Errors ──
    error ZeroAmount();
    error InsufficientStake();
    error LockNotExpired(uint256 unlockTime);
    error ContractPaused();
    error AprExceedsMax(uint256 requested, uint256 max);
    error InsufficientRewardPool();

    // ── Modifiers ──
    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    /**
     * @param _guguToken    Address of the GUGUToken contract
     * @param _aprBps       Initial APR in basis points (e.g. 1000 = 10%)
     * @param _minLock      Minimum lock period in seconds (0 = no lock)
     * @param _initialOwner Owner / admin address
     */
    constructor(
        address _guguToken,
        uint256 _aprBps,
        uint256 _minLock,
        address _initialOwner
    ) Ownable(_initialOwner) {
        if (_aprBps > MAX_APR_BPS) revert AprExceedsMax(_aprBps, MAX_APR_BPS);
        guguToken = IERC20(_guguToken);
        aprBps = _aprBps;
        minLockDuration = _minLock;
    }

    // ═══════════════════════════════════════════
    //                  Staking
    // ═══════════════════════════════════════════

    /// @notice Stake GUGU tokens
    /// @param amount Amount of GUGU to stake (must have prior approval)
    function stake(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        // Update accumulated rewards before changing balance
        _updateRewards(msg.sender);

        guguToken.safeTransferFrom(msg.sender, address(this), amount);

        StakeInfo storage info = stakes[msg.sender];
        info.amount += amount;
        // Only set stakedAt on first stake — additional deposits don't reset lock
        if (info.stakedAt == 0) {
            info.stakedAt = block.timestamp;
        }
        totalStaked += amount;

        emit Staked(msg.sender, amount);
    }

    // ═══════════════════════════════════════════
    //                Unstaking
    // ═══════════════════════════════════════════

    /// @notice Unstake GUGU and claim accumulated rewards
    /// @param amount Amount to unstake (0 = unstake all)
    function unstake(uint256 amount) external nonReentrant whenNotPaused {
        StakeInfo storage info = stakes[msg.sender];

        // Determine actual unstake amount
        uint256 unstakeAmount = amount == 0 ? info.amount : amount;
        if (unstakeAmount == 0 || unstakeAmount > info.amount) revert InsufficientStake();

        // Check lock period
        if (minLockDuration > 0) {
            uint256 unlockTime = info.stakedAt + minLockDuration;
            if (block.timestamp < unlockTime) revert LockNotExpired(unlockTime);
        }

        // Update accumulated rewards
        _updateRewards(msg.sender);

        // Collect rewards
        uint256 reward = info.rewardDebt;

        // Check reward pool BEFORE modifying totalStaked
        if (reward > 0) {
            uint256 rewardPool = _rewardPoolBalance();
            if (rewardPool < reward) revert InsufficientRewardPool();
        }

        info.rewardDebt = 0;
        info.amount -= unstakeAmount;
        totalStaked -= unstakeAmount;

        // Reset stakedAt when fully unstaked so next stake gets fresh lock
        if (info.amount == 0) {
            info.stakedAt = 0;
        }

        // Transfer staked tokens + rewards
        uint256 totalTransfer = unstakeAmount + reward;
        guguToken.safeTransfer(msg.sender, totalTransfer);

        emit Unstaked(msg.sender, unstakeAmount, reward);
    }

    // ═══════════════════════════════════════════
    //              Claim / Compound
    // ═══════════════════════════════════════════

    /// @notice Claim accumulated rewards without unstaking
    function claimRewards() external nonReentrant whenNotPaused {
        _updateRewards(msg.sender);

        StakeInfo storage info = stakes[msg.sender];
        uint256 reward = info.rewardDebt;
        if (reward == 0) revert ZeroAmount();

        // Check reward pool
        uint256 rewardPool = _rewardPoolBalance();
        if (rewardPool < reward) revert InsufficientRewardPool();

        info.rewardDebt = 0;
        guguToken.safeTransfer(msg.sender, reward);

        emit RewardsClaimed(msg.sender, reward);
    }

    /// @notice Compound: re-stake accumulated rewards
    function compound() external nonReentrant whenNotPaused {
        _updateRewards(msg.sender);

        StakeInfo storage info = stakes[msg.sender];
        uint256 reward = info.rewardDebt;
        if (reward == 0) revert ZeroAmount();

        // Check reward pool — compound uses reward pool tokens
        uint256 rewardPool = _rewardPoolBalance();
        if (rewardPool < reward) revert InsufficientRewardPool();

        info.rewardDebt = 0;
        info.amount += reward;
        totalStaked += reward;

        emit RewardsCompounded(msg.sender, reward);
    }

    // ═══════════════════════════════════════════
    //              Emergency Withdraw
    // ═══════════════════════════════════════════

    /// @notice Emergency withdraw: return staked tokens, forfeit rewards
    function emergencyWithdraw() external nonReentrant {
        StakeInfo storage info = stakes[msg.sender];
        uint256 amount = info.amount;
        if (amount == 0) revert InsufficientStake();

        // Reset user state entirely
        info.amount = 0;
        info.rewardDebt = 0;
        info.lastUpdateTime = block.timestamp;
        info.stakedAt = 0;
        totalStaked -= amount;

        guguToken.safeTransfer(msg.sender, amount);

        emit EmergencyWithdraw(msg.sender, amount);
    }

    // ═══════════════════════════════════════════
    //                  Queries
    // ═══════════════════════════════════════════

    /// @notice View pending (unclaimed) rewards for a user
    function pendingRewards(address user) external view returns (uint256) {
        StakeInfo storage info = stakes[user];
        if (info.amount == 0) return info.rewardDebt;
        uint256 elapsed = block.timestamp - info.lastUpdateTime;
        // Use user's snapshotted APR, reorder multiply-before-divide for precision
        uint256 userApr = info.lastAprBps > 0 ? info.lastAprBps : aprBps;
        uint256 newReward = (info.amount * userApr * elapsed) / (365 days * 10000);
        return info.rewardDebt + newReward;
    }

    /// @notice View the available reward pool balance (contract balance minus total staked)
    function rewardPoolBalance() external view returns (uint256) {
        return _rewardPoolBalance();
    }

    /// @notice Staking summary for a user
    function getUserInfo(address user)
        external
        view
        returns (
            uint256 stakedAmount,
            uint256 pending,
            uint256 stakedAt,
            uint256 unlockTime
        )
    {
        StakeInfo storage info = stakes[user];
        stakedAmount = info.amount;
        stakedAt = info.stakedAt;

        // Calculate pending rewards using user's snapshotted APR
        if (info.amount > 0) {
            uint256 elapsed = block.timestamp - info.lastUpdateTime;
            uint256 userApr = info.lastAprBps > 0 ? info.lastAprBps : aprBps;
            uint256 newReward = (info.amount * userApr * elapsed) / (365 days * 10000);
            pending = info.rewardDebt + newReward;
        } else {
            pending = info.rewardDebt;
        }

        // Unlock time
        unlockTime = (minLockDuration > 0 && info.stakedAt > 0) ? info.stakedAt + minLockDuration : 0;
    }

    // ═══════════════════════════════════════════
    //              Owner Management
    // ═══════════════════════════════════════════

    /// @notice Update annual interest rate (in basis points)
    function setApr(uint256 newAprBps) external onlyOwner {
        if (newAprBps > MAX_APR_BPS) revert AprExceedsMax(newAprBps, MAX_APR_BPS);
        emit AprUpdated(aprBps, newAprBps);
        aprBps = newAprBps;
    }

    /// @notice Update minimum lock duration
    function setMinLockDuration(uint256 newDuration) external onlyOwner {
        emit MinLockDurationUpdated(minLockDuration, newDuration);
        minLockDuration = newDuration;
    }

    /// @notice Pause staking
    function pause() external onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Unpause staking
    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /// @notice Fund the reward pool by transferring GUGU to this contract
    function fundRewardPool(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        guguToken.safeTransferFrom(msg.sender, address(this), amount);
        emit RewardPoolFunded(msg.sender, amount);
    }

    /// @notice Owner withdraws excess rewards from the pool (emergency / rebalance)
    function drainRewardPool(address to, uint256 amount) external onlyOwner {
        uint256 pool = _rewardPoolBalance();
        if (amount > pool) revert InsufficientRewardPool();
        guguToken.safeTransfer(to, amount);
        emit RewardPoolDrained(to, amount);
    }

    // ═══════════════════════════════════════════
    //              Internal Methods
    // ═══════════════════════════════════════════

    /// @dev Accrue rewards into rewardDebt based on elapsed time
    ///      Uses the user's snapshotted APR (not current global APR)
    ///      to prevent retroactive APR changes from affecting past rewards.
    function _updateRewards(address user) internal {
        StakeInfo storage info = stakes[user];
        if (info.amount > 0 && info.lastUpdateTime > 0) {
            uint256 elapsed = block.timestamp - info.lastUpdateTime;
            // Use snapshotted APR from last update; fallback to global for first-time
            uint256 userApr = info.lastAprBps > 0 ? info.lastAprBps : aprBps;
            uint256 reward = (info.amount * userApr * elapsed) / (365 days * 10000);
            info.rewardDebt += reward;
        }
        info.lastUpdateTime = block.timestamp;
        info.lastAprBps = aprBps; // Snapshot current APR for next calculation
    }

    /// @dev Reward pool = contract token balance - total staked principal
    function _rewardPoolBalance() internal view returns (uint256) {
        uint256 balance = guguToken.balanceOf(address(this));
        if (balance <= totalStaked) return 0;
        return balance - totalStaked;
    }
}

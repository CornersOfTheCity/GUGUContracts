// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {GUGUToken} from "../src/GUGUToken.sol";
import {TokenStaking} from "../src/TokenStaking.sol";

contract TokenStakingTest is Test {
    GUGUToken public token;
    TokenStaking public staking;

    address public owner = address(0xA);
    address public user1 = address(0xB);
    address public user2 = address(0xC);

    uint256 constant INITIAL_APR = 1000; // 10%
    uint256 constant MIN_LOCK = 7 days;
    uint256 constant REWARD_POOL = 10_000_000 * 1e18;
    uint256 constant USER_BALANCE = 100_000 * 1e18;

    function setUp() public {
        vm.startPrank(owner);

        // Deploy token
        token = new GUGUToken(owner);

        // Deploy staking contract
        staking = new TokenStaking(address(token), INITIAL_APR, MIN_LOCK, owner);

        // Mint tokens
        token.mint(owner, REWARD_POOL);
        token.mint(user1, USER_BALANCE);
        token.mint(user2, USER_BALANCE);

        // Fund reward pool
        token.approve(address(staking), REWARD_POOL);
        staking.fundRewardPool(REWARD_POOL);

        vm.stopPrank();
    }

    // ═══════════════════════════════════════════
    //              Basic Staking
    // ═══════════════════════════════════════════

    function test_Stake() public {
        uint256 stakeAmount = 10_000 * 1e18;

        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        vm.stopPrank();

        (uint256 stakedAmount,,,) = staking.getUserInfo(user1);
        assertEq(stakedAmount, stakeAmount);
        assertEq(staking.totalStaked(), stakeAmount);
        assertEq(token.balanceOf(user1), USER_BALANCE - stakeAmount);
    }

    function test_StakeZeroReverts() public {
        vm.prank(user1);
        vm.expectRevert(TokenStaking.ZeroAmount.selector);
        staking.stake(0);
    }

    function test_StakeMultipleTimes() public {
        uint256 amount1 = 5_000 * 1e18;
        uint256 amount2 = 3_000 * 1e18;

        vm.startPrank(user1);
        token.approve(address(staking), amount1 + amount2);
        staking.stake(amount1);
        skip(1 days);
        staking.stake(amount2);
        vm.stopPrank();

        (uint256 stakedAmount,,,) = staking.getUserInfo(user1);
        assertEq(stakedAmount, amount1 + amount2);
    }

    // ═══════════════════════════════════════════
    //              Reward Calculation
    // ═══════════════════════════════════════════

    function test_PendingRewardsAccumulate() public {
        uint256 stakeAmount = 100_000 * 1e18;

        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        vm.stopPrank();

        // Fast forward 365 days
        skip(365 days);

        uint256 pending = staking.pendingRewards(user1);
        // 100,000 * 10% = 10,000 GUGU per year
        uint256 expected = 10_000 * 1e18;
        assertApproxEqRel(pending, expected, 1e15); // 0.1% tolerance
    }

    function test_PendingRewardsPartialYear() public {
        uint256 stakeAmount = 100_000 * 1e18;

        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        vm.stopPrank();

        // Fast forward 30 days
        skip(30 days);

        uint256 pending = staking.pendingRewards(user1);
        // 100,000 * 10% * 30/365 ≈ 821.9178 GUGU
        uint256 expected = (stakeAmount * INITIAL_APR * 30 days) / (365 days * 10000);
        assertEq(pending, expected);
    }

    // ═══════════════════════════════════════════
    //                Unstaking
    // ═══════════════════════════════════════════

    function test_UnstakeAll() public {
        uint256 stakeAmount = 50_000 * 1e18;

        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        vm.stopPrank();

        // Wait for lock to expire
        skip(MIN_LOCK + 1);

        vm.prank(user1);
        staking.unstake(0); // 0 means unstake all

        (uint256 stakedAmount,,,) = staking.getUserInfo(user1);
        assertEq(stakedAmount, 0);
        assertEq(staking.totalStaked(), 0);
        // user should have original balance + rewards
        assertGt(token.balanceOf(user1), USER_BALANCE - 1); // slight rounding
    }

    function test_UnstakePartial() public {
        uint256 stakeAmount = 50_000 * 1e18;
        uint256 unstakeAmount = 20_000 * 1e18;

        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        vm.stopPrank();

        skip(MIN_LOCK + 1);

        vm.prank(user1);
        staking.unstake(unstakeAmount);

        (uint256 stakedAmount,,,) = staking.getUserInfo(user1);
        assertEq(stakedAmount, stakeAmount - unstakeAmount);
        assertEq(staking.totalStaked(), stakeAmount - unstakeAmount);
    }

    function test_UnstakeBeforeLockReverts() public {
        uint256 stakeAmount = 10_000 * 1e18;

        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);

        vm.expectRevert(
            abi.encodeWithSelector(
                TokenStaking.LockNotExpired.selector,
                block.timestamp + MIN_LOCK
            )
        );
        staking.unstake(stakeAmount);
        vm.stopPrank();
    }

    function test_UnstakeInsufficientReverts() public {
        vm.prank(user1);
        vm.expectRevert(TokenStaking.InsufficientStake.selector);
        staking.unstake(1000 * 1e18);
    }

    // ═══════════════════════════════════════════
    //              Claim Rewards
    // ═══════════════════════════════════════════

    function test_ClaimRewards() public {
        uint256 stakeAmount = 100_000 * 1e18;

        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        vm.stopPrank();

        skip(30 days);

        uint256 pendingBefore = staking.pendingRewards(user1);
        assertGt(pendingBefore, 0);

        uint256 balanceBefore = token.balanceOf(user1);

        vm.prank(user1);
        staking.claimRewards();

        uint256 balanceAfter = token.balanceOf(user1);
        assertApproxEqRel(balanceAfter - balanceBefore, pendingBefore, 1e15);

        // Pending should be ~0 after claim
        assertEq(staking.pendingRewards(user1), 0);
    }

    // ═══════════════════════════════════════════
    //               Compound
    // ═══════════════════════════════════════════

    function test_Compound() public {
        uint256 stakeAmount = 100_000 * 1e18;

        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        vm.stopPrank();

        skip(365 days);

        uint256 pendingBefore = staking.pendingRewards(user1);

        vm.prank(user1);
        staking.compound();

        (uint256 stakedAmount,,,) = staking.getUserInfo(user1);
        // Principal should now include the compounded reward
        assertApproxEqRel(stakedAmount, stakeAmount + pendingBefore, 1e15);
    }

    // ═══════════════════════════════════════════
    //           Emergency Withdraw
    // ═══════════════════════════════════════════

    function test_EmergencyWithdraw() public {
        uint256 stakeAmount = 50_000 * 1e18;

        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        vm.stopPrank();

        skip(30 days); // rewards accrue but will be forfeited

        vm.prank(user1);
        staking.emergencyWithdraw();

        (uint256 stakedAmount, uint256 pending,,) = staking.getUserInfo(user1);
        assertEq(stakedAmount, 0);
        assertEq(pending, 0);
        assertEq(token.balanceOf(user1), USER_BALANCE); // exactly original balance, no rewards
    }

    function test_EmergencyWithdrawNoStakeReverts() public {
        vm.prank(user1);
        vm.expectRevert(TokenStaking.InsufficientStake.selector);
        staking.emergencyWithdraw();
    }

    // ═══════════════════════════════════════════
    //              Admin Functions
    // ═══════════════════════════════════════════

    function test_SetApr() public {
        vm.prank(owner);
        staking.setApr(2000); // 20%

        assertEq(staking.aprBps(), 2000);
    }

    function test_SetAprExceedsMaxReverts() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(TokenStaking.AprExceedsMax.selector, 6000, 5000)
        );
        staking.setApr(6000); // 60% > 50% max
    }

    function test_SetAprNonOwnerReverts() public {
        vm.prank(user1);
        vm.expectRevert();
        staking.setApr(500);
    }

    function test_SetMinLockDuration() public {
        vm.prank(owner);
        staking.setMinLockDuration(30 days);

        assertEq(staking.minLockDuration(), 30 days);
    }

    function test_PauseAndUnpause() public {
        vm.prank(owner);
        staking.pause();
        assertTrue(staking.paused());

        // Staking should revert when paused
        vm.startPrank(user1);
        token.approve(address(staking), 1000 * 1e18);
        vm.expectRevert(TokenStaking.ContractPaused.selector);
        staking.stake(1000 * 1e18);
        vm.stopPrank();

        // Unpause
        vm.prank(owner);
        staking.unpause();
        assertFalse(staking.paused());

        // Staking should work again
        vm.startPrank(user1);
        staking.stake(1000 * 1e18);
        vm.stopPrank();
    }

    function test_DrainRewardPool() public {
        uint256 drainAmount = 1_000_000 * 1e18;
        uint256 ownerBalBefore = token.balanceOf(owner);

        vm.prank(owner);
        staking.drainRewardPool(owner, drainAmount);

        assertEq(token.balanceOf(owner), ownerBalBefore + drainAmount);
    }

    function test_DrainRewardPoolExceedsAvailableReverts() public {
        vm.prank(owner);
        vm.expectRevert(TokenStaking.InsufficientRewardPool.selector);
        staking.drainRewardPool(owner, REWARD_POOL + 1);
    }

    // ═══════════════════════════════════════════
    //              APR Change Mid-Stake
    // ═══════════════════════════════════════════

    function test_AprChangeMidStake() public {
        uint256 stakeAmount = 100_000 * 1e18;

        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        vm.stopPrank();

        // Accrue 30 days at 10%
        skip(30 days);
        uint256 pendingAt10Pct = staking.pendingRewards(user1);

        // Owner changes APR to 20%
        vm.prank(owner);
        staking.setApr(2000);

        // Stake again to trigger reward checkpoint (user adds 0 is not allowed, so claim)
        vm.prank(user1);
        staking.claimRewards();

        // Accrue another 30 days at 20%
        skip(30 days);
        uint256 pendingAt20Pct = staking.pendingRewards(user1);

        // Reward at 20% should be ~2x the reward at 10%
        assertApproxEqRel(pendingAt20Pct, pendingAt10Pct * 2, 1e15);
    }

    // ═══════════════════════════════════════════
    //              Multi-User Scenario
    // ═══════════════════════════════════════════

    function test_MultiUserStaking() public {
        uint256 stakeAmount = 50_000 * 1e18;

        // User1 stakes
        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        vm.stopPrank();

        // User2 stakes
        vm.startPrank(user2);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        vm.stopPrank();

        assertEq(staking.totalStaked(), stakeAmount * 2);

        skip(365 days);

        // Both users should have same pending rewards (staked same amount at same time)
        uint256 pending1 = staking.pendingRewards(user1);
        uint256 pending2 = staking.pendingRewards(user2);
        assertEq(pending1, pending2);

        // 50,000 * 10% = 5,000 GUGU each
        assertApproxEqRel(pending1, 5_000 * 1e18, 1e15);
    }

    // ═══════════════════════════════════════════
    //              Reward Pool Balance
    // ═══════════════════════════════════════════

    function test_RewardPoolBalance() public {
        assertEq(staking.rewardPoolBalance(), REWARD_POOL);

        // After staking, reward pool stays the same (staked principal tracked separately)
        vm.startPrank(user1);
        token.approve(address(staking), 10_000 * 1e18);
        staking.stake(10_000 * 1e18);
        vm.stopPrank();

        assertEq(staking.rewardPoolBalance(), REWARD_POOL);
    }

    function test_FundRewardPool() public {
        uint256 extra = 5_000_000 * 1e18;

        vm.startPrank(owner);
        token.mint(owner, extra);
        token.approve(address(staking), extra);
        staking.fundRewardPool(extra);
        vm.stopPrank();

        assertEq(staking.rewardPoolBalance(), REWARD_POOL + extra);
    }

    // ═══════════════════════════════════════════
    //         Bug Fix Verification Tests
    // ═══════════════════════════════════════════

    /// @notice Fix #1: APR snapshot — changing APR should NOT retroactively affect past rewards
    function test_AprSnapshot_NoRetroactiveEffect() public {
        uint256 stakeAmount = 100_000 * 1e18;

        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        vm.stopPrank();

        // Accrue 30 days at 10%
        skip(30 days);
        uint256 pendingBefore = staking.pendingRewards(user1);
        // expected: 100,000 * 10% * 30/365
        uint256 expectedAt10Pct = (stakeAmount * 1000 * 30 days) / (365 days * 10000);
        assertEq(pendingBefore, expectedAt10Pct);

        // Admin changes APR to 5% — should NOT affect the 30 days already elapsed
        vm.prank(owner);
        staking.setApr(500);

        // Pending rewards should still be the same (calculated with old 10% snapshot)
        uint256 pendingAfterAprChange = staking.pendingRewards(user1);
        assertEq(pendingAfterAprChange, pendingBefore, "APR change should not retroactively change past rewards");
    }

    /// @notice Fix #2: rewardPool check before totalStaked modification in unstake
    function test_UnstakeRewardPoolCheck_BeforeTotalStakedChange() public {
        uint256 stakeAmount = 50_000 * 1e18;

        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        vm.stopPrank();

        // Wait for lock + accrue some rewards
        skip(MIN_LOCK + 365 days);

        // Calculate pending rewards and drain pool leaving just enough
        uint256 pending = staking.pendingRewards(user1);
        uint256 pool = staking.rewardPoolBalance();
        // Leave exactly pending + small margin in pool
        uint256 drainAmount = pool - pending - 1;
        if (drainAmount > 0) {
            vm.prank(owner);
            staking.drainRewardPool(owner, drainAmount);
        }

        // The unstake should work — reward pool has just enough
        vm.prank(user1);
        staking.unstake(0);

        // Verify user got their tokens back
        assertGt(token.balanceOf(user1), USER_BALANCE - 1);
    }

    /// @notice Fix #4: Lock period NOT reset on additional stake
    function test_LockNotResetOnAdditionalStake() public {
        uint256 amount1 = 30_000 * 1e18;
        uint256 amount2 = 10_000 * 1e18;

        vm.startPrank(user1);
        token.approve(address(staking), amount1 + amount2);
        staking.stake(amount1);

        // Wait 5 days (not yet past 7-day lock)
        skip(5 days);

        // Stake more — should NOT reset the lock timer
        staking.stake(amount2);

        // Wait 2 more days (total 7 days from first stake)
        skip(2 days + 1);

        // Should be able to unstake (7 days passed since FIRST stake)
        staking.unstake(amount1);
        vm.stopPrank();

        (uint256 remaining,,,) = staking.getUserInfo(user1);
        assertEq(remaining, amount2);
    }

    /// @notice Fix #4b: Full unstake resets stakedAt so next stake gets fresh lock
    function test_FullUnstakeResetsLock() public {
        uint256 stakeAmount = 10_000 * 1e18;

        vm.startPrank(user1);
        token.approve(address(staking), stakeAmount * 2);
        staking.stake(stakeAmount);

        skip(MIN_LOCK + 1);
        staking.unstake(0); // full unstake

        // Re-stake — should get a new lock period
        staking.stake(stakeAmount);

        // Trying to unstake immediately should fail (new lock)
        vm.expectRevert();
        staking.unstake(stakeAmount);

        vm.stopPrank();
    }
}


// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {GUGUToken} from "../src/GUGUToken.sol";
import {GUGUNFT} from "../src/GUGUNFT.sol";
import {NFTStaking} from "../src/NFTStaking.sol";

contract NFTStakingTest is Test {
    GUGUToken public token;
    GUGUNFT public nft;
    NFTStaking public staking;

    address public owner = address(this);
    address public alice = makeAddr("alice");

    function setUp() public {
        token = new GUGUToken(10_000_000 * 1e18);
        nft = new GUGUNFT();
        staking = new NFTStaking(address(token), address(nft));

        // 预充值 Staking 合约的 Token 奖励池
        token.transfer(address(staking), 1_000_000 * 1e18);

        // 给 alice 铸造一些 NFT
        nft.addMinter(address(this));
        nft.mint(alice, GUGUNFT.Rarity.Founder); // tokenId 1
        nft.mint(alice, GUGUNFT.Rarity.Pro);     // tokenId 2
        nft.mint(alice, GUGUNFT.Rarity.Basic);   // tokenId 3
    }

    // ── 质押 ──

    function test_Stake() public {
        vm.startPrank(alice);
        nft.approve(address(staking), 1);
        staking.stake(1);
        vm.stopPrank();

        assertEq(nft.ownerOf(1), address(staking));
        assertEq(staking.stakedCountOf(alice), 1);

        uint256[] memory staked = staking.stakedTokensOf(alice);
        assertEq(staked.length, 1);
        assertEq(staked[0], 1);
    }

    function test_StakeBatch() public {
        vm.startPrank(alice);
        nft.approve(address(staking), 1);
        nft.approve(address(staking), 2);
        nft.approve(address(staking), 3);

        uint256[] memory tokenIds = new uint256[](3);
        tokenIds[0] = 1;
        tokenIds[1] = 2;
        tokenIds[2] = 3;
        staking.stakeBatch(tokenIds);
        vm.stopPrank();

        assertEq(staking.stakedCountOf(alice), 3);
    }

    // ── 奖励计算 ──

    function test_RewardsFounder() public {
        vm.startPrank(alice);
        nft.approve(address(staking), 1);
        staking.stake(1); // Founder: 50 GUGU/天
        vm.stopPrank();

        // 快进 1 天
        vm.warp(block.timestamp + 1 days);

        uint256 pending = staking.pendingRewards(alice);
        assertEq(pending, 50 * 1e18); // 50 GUGU
    }

    function test_RewardsPro() public {
        vm.startPrank(alice);
        nft.approve(address(staking), 2);
        staking.stake(2); // Pro: 15 GUGU/天
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days);

        uint256 pending = staking.pendingRewards(alice);
        assertEq(pending, 15 * 1e18);
    }

    function test_RewardsBasic() public {
        vm.startPrank(alice);
        nft.approve(address(staking), 3);
        staking.stake(3); // Basic: 3 GUGU/天
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days);

        uint256 pending = staking.pendingRewards(alice);
        assertEq(pending, 3 * 1e18);
    }

    function test_RewardsMultipleDays() public {
        vm.startPrank(alice);
        nft.approve(address(staking), 1);
        staking.stake(1); // Founder
        vm.stopPrank();

        vm.warp(block.timestamp + 7 days); // 7 天

        uint256 pending = staking.pendingRewards(alice);
        assertEq(pending, 350 * 1e18); // 50 * 7 = 350
    }

    // ── 领取奖励 ──

    function test_ClaimRewards() public {
        vm.startPrank(alice);
        nft.approve(address(staking), 1);
        staking.stake(1);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days);

        vm.prank(alice);
        staking.claimRewards();

        assertEq(token.balanceOf(alice), 50 * 1e18);

        // 领取后 pending 应为 0
        assertEq(staking.pendingRewards(alice), 0);
    }

    // ── 取消质押 ──

    function test_Unstake() public {
        vm.startPrank(alice);
        nft.approve(address(staking), 1);
        staking.stake(1);
        vm.stopPrank();

        vm.warp(block.timestamp + 2 days);

        vm.prank(alice);
        staking.unstake(1);

        assertEq(nft.ownerOf(1), alice); // NFT 归还
        assertEq(token.balanceOf(alice), 100 * 1e18); // 50 * 2 = 100
        assertEq(staking.stakedCountOf(alice), 0);
    }

    function test_RevertUnstakeNotOwner() public {
        vm.startPrank(alice);
        nft.approve(address(staking), 1);
        staking.stake(1);
        vm.stopPrank();

        vm.prank(makeAddr("bob"));
        vm.expectRevert();
        staking.unstake(1);
    }

    // ── 多个 NFT 质押和领取 ──

    function test_MultipleStakesReward() public {
        vm.startPrank(alice);
        nft.approve(address(staking), 1);
        nft.approve(address(staking), 2);
        nft.approve(address(staking), 3);
        staking.stake(1); // Founder: 50/天
        staking.stake(2); // Pro: 15/天
        staking.stake(3); // Basic: 3/天
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days);

        uint256 pending = staking.pendingRewards(alice);
        assertEq(pending, 68 * 1e18); // 50 + 15 + 3 = 68
    }
}

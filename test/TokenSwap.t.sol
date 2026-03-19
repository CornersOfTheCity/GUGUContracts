// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {GUGUToken} from "../src/GUGUToken.sol";
import {TokenSwap} from "../src/TokenSwap.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev 简单的 Mock ERC-20 用于测试
contract MockToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 10_000_000 * 1e18);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract TokenSwapTest is Test {
    GUGUToken public gugu;
    MockToken public usdt;
    TokenSwap public swap;

    address public owner = address(this);
    address public alice = makeAddr("alice");

    uint256 public constant RATE_GUGU_TO_USDT = 0.1 * 1e18; // 1 GUGU = 0.1 USDT
    uint256 public constant RATE_USDT_TO_GUGU = 10 * 1e18;  // 1 USDT = 10 GUGU

    function setUp() public {
        gugu = new GUGUToken(10_000_000 * 1e18);
        usdt = new MockToken("Mock USDT", "USDT");
        swap = new TokenSwap();

        // 添加交易对 GUGU <=> USDT
        swap.addPair(address(gugu), address(usdt), RATE_GUGU_TO_USDT, RATE_USDT_TO_GUGU);

        // 存入流动性
        gugu.approve(address(swap), 1_000_000 * 1e18);
        swap.addLiquidity(0, address(gugu), 1_000_000 * 1e18);

        usdt.approve(address(swap), 100_000 * 1e18);
        swap.addLiquidity(0, address(usdt), 100_000 * 1e18);

        // 给 alice 一些代币
        gugu.transfer(alice, 10_000 * 1e18);
        usdt.transfer(alice, 1_000 * 1e18);
    }

    // ── 兑换 ──

    function test_SwapGuguToUsdt() public {
        vm.startPrank(alice);
        gugu.approve(address(swap), 100 * 1e18);
        swap.swap(0, address(gugu), 100 * 1e18);
        vm.stopPrank();

        // 100 GUGU * 0.1 = 10 USDT, 扣手续费 0.3% = 9.97 USDT
        uint256 expectedOut = 10 * 1e18 - (10 * 1e18 * 30 / 10000);
        assertEq(usdt.balanceOf(alice), 1_000 * 1e18 + expectedOut);
    }

    function test_SwapUsdtToGugu() public {
        vm.startPrank(alice);
        usdt.approve(address(swap), 10 * 1e18);
        swap.swap(0, address(usdt), 10 * 1e18);
        vm.stopPrank();

        // 10 USDT * 10 = 100 GUGU, 扣手续费 0.3% = 99.7 GUGU
        uint256 expectedOut = 100 * 1e18 - (100 * 1e18 * 30 / 10000);
        assertEq(gugu.balanceOf(alice), 10_000 * 1e18 + expectedOut);
    }

    // ── 预估查询 ──

    function test_GetAmountOut() public view {
        (uint256 amountOut, uint256 fee) = swap.getAmountOut(0, address(gugu), 100 * 1e18);
        assertEq(amountOut + fee, 10 * 1e18);
        assertEq(fee, 10 * 1e18 * 30 / 10000);
    }

    // ── 交易对管理 ──

    function test_AddPair() public view {
        assertEq(swap.pairCount(), 1);
        TokenSwap.SwapPair memory pair = swap.getPair(0);
        assertEq(pair.tokenA, address(gugu));
        assertEq(pair.tokenB, address(usdt));
        assertTrue(pair.active);
    }

    function test_PausePair() public {
        swap.setPairActive(0, false);

        vm.startPrank(alice);
        gugu.approve(address(swap), 100 * 1e18);
        vm.expectRevert();
        swap.swap(0, address(gugu), 100 * 1e18);
        vm.stopPrank();
    }

    // ── 手续费 ──

    function test_SetFeeRate() public {
        swap.setFeeRate(50); // 0.5%
        assertEq(swap.feeRate(), 50);
    }

    function test_RevertFeeRateTooHigh() public {
        vm.expectRevert();
        swap.setFeeRate(1500); // 15% > 10% max
    }

    function test_ZeroFee() public {
        swap.setFeeRate(0);

        vm.startPrank(alice);
        gugu.approve(address(swap), 100 * 1e18);
        swap.swap(0, address(gugu), 100 * 1e18);
        vm.stopPrank();

        // 100 GUGU * 0.1 = 10 USDT, 0 fee
        assertEq(usdt.balanceOf(alice), 1_010 * 1e18);
    }

    // ── 流动性 ──

    function test_RemoveLiquidity() public {
        uint256 beforeBal = gugu.balanceOf(owner);
        swap.removeLiquidity(0, address(gugu), 100 * 1e18);
        assertEq(gugu.balanceOf(owner) - beforeBal, 100 * 1e18);
    }

    function test_RevertInsufficientLiquidity() public {
        // Alice 尝试兑换超过流动性的金额
        gugu.transfer(alice, 5_000_000 * 1e18);

        vm.startPrank(alice);
        gugu.approve(address(swap), 5_000_000 * 1e18);
        vm.expectRevert();
        swap.swap(0, address(gugu), 5_000_000 * 1e18); // 需要 500,000 USDT, 只有 100,000
        vm.stopPrank();
    }

    // ── 权限 ──

    function test_RevertAddPairNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        swap.addPair(address(gugu), address(usdt), 1e18, 1e18);
    }
}

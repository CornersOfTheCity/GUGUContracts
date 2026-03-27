// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {GUGUToken} from "../src/GUGUToken.sol";
import {TokenSwap} from "../src/TokenSwap.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Mock 稳定币
contract MockUSDT is ERC20 {
    constructor() ERC20("Mock USDT", "USDT") {
        _mint(msg.sender, 10_000_000 * 1e18);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract TokenSwapTest is Test {
    GUGUToken public gugu;
    MockUSDT public usdt;
    TokenSwap public sale;

    address public owner = address(this);
    address public alice = makeAddr("alice");

    // 1 GUGU = 0.1 USDT
    uint256 public constant PRICE = 0.1 * 1e18;

    receive() external payable {}

    function setUp() public {
        gugu = new GUGUToken(owner);
        gugu.mint(owner, 10_000_000 * 1e18);
        usdt = new MockUSDT();

        sale = new TokenSwap(address(gugu), address(usdt), PRICE, owner);

        // 存入 GUGU 库存
        gugu.transfer(address(sale), 1_000_000 * 1e18);

        // 给 alice USDT
        usdt.transfer(alice, 10_000 * 1e18);
    }

    // ═══════════════════════════════════════════
    //                  购买测试
    // ═══════════════════════════════════════════

    function test_Buy() public {
        vm.startPrank(alice);
        usdt.approve(address(sale), 10 * 1e18);
        sale.buy(10 * 1e18);
        vm.stopPrank();

        // 10 USDT / 0.1 = 100 GUGU
        assertEq(gugu.balanceOf(alice), 100 * 1e18);
        assertEq(usdt.balanceOf(address(sale)), 10 * 1e18);
    }

    function test_BuyMultipleTimes() public {
        vm.startPrank(alice);
        usdt.approve(address(sale), 100 * 1e18);

        sale.buy(10 * 1e18);
        sale.buy(20 * 1e18);

        vm.stopPrank();

        // 总共 30 USDT → 300 GUGU
        assertEq(gugu.balanceOf(alice), 300 * 1e18);
    }

    function test_RevertBuyWhenPaused() public {
        sale.setPaused(true);

        vm.startPrank(alice);
        usdt.approve(address(sale), 10 * 1e18);
        vm.expectRevert(TokenSwap.SaleIsPaused.selector);
        sale.buy(10 * 1e18);
        vm.stopPrank();
    }

    function test_RevertBuyZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(TokenSwap.ZeroAmount.selector);
        sale.buy(0);
    }

    function test_RevertBuyInsufficientSupply() public {
        // Alice 有超多 USDT，但合约只有 100万 GUGU
        usdt.mint(alice, 500_000 * 1e18);

        vm.startPrank(alice);
        usdt.approve(address(sale), 500_000 * 1e18);
        vm.expectRevert();
        sale.buy(500_000 * 1e18); // 想买 500万 GUGU，但只有 100万
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════
    //                  查询测试
    // ═══════════════════════════════════════════

    function test_GetAmountOut() public view {
        uint256 amount = sale.getAmountOut(10 * 1e18);
        assertEq(amount, 100 * 1e18); // 10 USDT → 100 GUGU
    }

    function test_RemainingSupply() public view {
        assertEq(sale.remainingSupply(), 1_000_000 * 1e18);
    }

    // ═══════════════════════════════════════════
    //               价格管理
    // ═══════════════════════════════════════════

    function test_SetPrice() public {
        // 涨价: 1 GUGU = 0.2 USDT
        sale.setPrice(0.2 * 1e18);
        assertEq(sale.price(), 0.2 * 1e18);

        // 10 USDT 现在只能买 50 GUGU
        uint256 amount = sale.getAmountOut(10 * 1e18);
        assertEq(amount, 50 * 1e18);
    }

    function test_RevertSetPriceZero() public {
        vm.expectRevert(TokenSwap.InvalidPrice.selector);
        sale.setPrice(0);
    }

    function test_RevertSetPriceNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        sale.setPrice(0.5 * 1e18);
    }

    // ═══════════════════════════════════════════
    //               提取代币
    // ═══════════════════════════════════════════

    function test_WithdrawToken_USDT() public {
        // Alice 先购买，合约收到 USDT
        vm.startPrank(alice);
        usdt.approve(address(sale), 100 * 1e18);
        sale.buy(100 * 1e18);
        vm.stopPrank();

        // Owner 提取收到的 USDT
        uint256 ownerBefore = usdt.balanceOf(owner);
        sale.withdrawToken(address(usdt), 100 * 1e18);
        assertEq(usdt.balanceOf(owner), ownerBefore + 100 * 1e18);
    }

    function test_WithdrawToken_GUGU() public {
        uint256 ownerBefore = gugu.balanceOf(owner);
        sale.withdrawToken(address(gugu), 500_000 * 1e18);
        assertEq(gugu.balanceOf(owner), ownerBefore + 500_000 * 1e18);
    }

    function test_WithdrawETH() public {
        vm.deal(address(sale), 1 ether);
        uint256 ownerBefore = owner.balance;

        sale.withdrawETH();

        assertEq(address(sale).balance, 0);
        assertEq(owner.balance, ownerBefore + 1 ether);
    }

    function test_RevertWithdrawNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        sale.withdrawToken(address(usdt), 1e18);
    }

    // ═══════════════════════════════════════════
    //               暂停/恢复
    // ═══════════════════════════════════════════

    function test_PauseAndResume() public {
        sale.setPaused(true);
        assertTrue(sale.paused());

        sale.setPaused(false);
        assertFalse(sale.paused());

        // 恢复后可以购买
        vm.startPrank(alice);
        usdt.approve(address(sale), 10 * 1e18);
        sale.buy(10 * 1e18);
        vm.stopPrank();

        assertEq(gugu.balanceOf(alice), 100 * 1e18);
    }
}

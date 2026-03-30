// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {GUGUToken} from "../src/GUGUToken.sol";
import {TokenSwap} from "../src/TokenSwap.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Mock stablecoin
contract MockUSDT is ERC20 {
    constructor() ERC20("Mock USDT", "USDT") {
        _mint(msg.sender, 10_000_000 * 1e18);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {
        _mint(msg.sender, 10_000_000 * 1e18);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract TokenSwapTest is Test {
    GUGUToken public gugu;
    MockUSDT public usdt;
    MockUSDC public usdc;
    TokenSwap public sale;

    address public owner = address(this);
    address public alice = makeAddr("alice");

    // 1 GUGU = 0.1 USDT (buy), 0.08 USDT (sell)
    uint256 public constant BUY_PRICE = 0.1 * 1e18;
    uint256 public constant SELL_PRICE = 0.08 * 1e18;

    receive() external payable {}

    function setUp() public {
        gugu = new GUGUToken(owner);
        gugu.mint(owner, 10_000_000 * 1e18);
        usdt = new MockUSDT();
        usdc = new MockUSDC();

        // New constructor: (saleToken, owner)
        sale = new TokenSwap(address(gugu), owner);

        // Add USDT as pay token
        sale.addPayToken(address(usdt), BUY_PRICE, SELL_PRICE);

        // Deposit GUGU inventory
        gugu.transfer(address(sale), 1_000_000 * 1e18);

        // Give alice USDT
        usdt.transfer(alice, 10_000 * 1e18);
    }

    // ═══════════════════════════════════════════
    //                  Buy Tests
    // ═══════════════════════════════════════════

    function test_Buy() public {
        vm.startPrank(alice);
        usdt.approve(address(sale), 10 * 1e18);
        sale.buy(address(usdt), 10 * 1e18);
        vm.stopPrank();

        // 10 USDT / 0.1 = 100 GUGU
        assertEq(gugu.balanceOf(alice), 100 * 1e18);
        assertEq(usdt.balanceOf(address(sale)), 10 * 1e18);
    }

    function test_BuyMultipleTimes() public {
        vm.startPrank(alice);
        usdt.approve(address(sale), 100 * 1e18);

        sale.buy(address(usdt), 10 * 1e18);
        sale.buy(address(usdt), 20 * 1e18);

        vm.stopPrank();

        // 30 USDT → 300 GUGU
        assertEq(gugu.balanceOf(alice), 300 * 1e18);
    }

    function test_RevertBuyWhenPaused() public {
        sale.setPaused(true);

        vm.startPrank(alice);
        usdt.approve(address(sale), 10 * 1e18);
        vm.expectRevert(TokenSwap.SaleIsPaused.selector);
        sale.buy(address(usdt), 10 * 1e18);
        vm.stopPrank();
    }

    function test_RevertBuyZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(TokenSwap.ZeroAmount.selector);
        sale.buy(address(usdt), 0);
    }

    function test_RevertBuyTokenNotEnabled() public {
        vm.prank(alice);
        vm.expectRevert(TokenSwap.TokenNotEnabled.selector);
        sale.buy(address(usdc), 10 * 1e18);
    }

    function test_RevertBuyInsufficientSupply() public {
        usdt.mint(alice, 500_000 * 1e18);

        vm.startPrank(alice);
        usdt.approve(address(sale), 500_000 * 1e18);
        vm.expectRevert();
        sale.buy(address(usdt), 500_000 * 1e18);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════
    //                  Query Tests
    // ═══════════════════════════════════════════

    function test_GetBuyAmountOut() public view {
        uint256 amount = sale.getBuyAmountOut(address(usdt), 10 * 1e18);
        assertEq(amount, 100 * 1e18); // 10 USDT → 100 GUGU
    }

    function test_GetSellAmountOut() public view {
        uint256 amount = sale.getSellAmountOut(address(usdt), 100 * 1e18);
        assertEq(amount, 8 * 1e18); // 100 GUGU → 8 USDT (sell price 0.08)
    }

    function test_RemainingSupply() public view {
        assertEq(sale.remainingSupply(), 1_000_000 * 1e18);
    }

    // ═══════════════════════════════════════════
    //             Multi-Token Tests
    // ═══════════════════════════════════════════

    function test_AddMultipleTokens() public {
        sale.addPayToken(address(usdc), 0.1 * 1e18, 0.09 * 1e18);

        address[] memory tokens = sale.getPayTokenList();
        assertEq(tokens.length, 2);
        assertEq(tokens[0], address(usdt));
        assertEq(tokens[1], address(usdc));
    }

    function test_BuyWithSecondToken() public {
        sale.addPayToken(address(usdc), 0.2 * 1e18, 0.15 * 1e18);

        usdc.transfer(alice, 10_000 * 1e18);

        vm.startPrank(alice);
        usdc.approve(address(sale), 20 * 1e18);
        sale.buy(address(usdc), 20 * 1e18);
        vm.stopPrank();

        // 20 USDC / 0.2 = 100 GUGU
        assertEq(gugu.balanceOf(alice), 100 * 1e18);
    }

    function test_RemoveToken() public {
        sale.addPayToken(address(usdc), 0.1 * 1e18, 0.09 * 1e18);
        sale.removePayToken(address(usdt));

        address[] memory tokens = sale.getPayTokenList();
        assertEq(tokens.length, 1);
        assertEq(tokens[0], address(usdc));

        // USDT no longer works
        vm.prank(alice);
        vm.expectRevert(TokenSwap.TokenNotEnabled.selector);
        sale.buy(address(usdt), 10 * 1e18);
    }

    // ═══════════════════════════════════════════
    //              Buyback Tests
    // ═══════════════════════════════════════════

    function test_SellBuyback() public {
        // Enable buyback
        sale.setBuybackEnabled(true);

        // Deposit USDT to sale contract for buyback pool
        usdt.transfer(address(sale), 1_000 * 1e18);

        // Alice buys GUGU first
        vm.startPrank(alice);
        usdt.approve(address(sale), 10 * 1e18);
        sale.buy(address(usdt), 10 * 1e18);
        // Alice now has 100 GUGU

        // Alice sells 50 GUGU back
        gugu.approve(address(sale), 50 * 1e18);
        sale.sell(address(usdt), 50 * 1e18);
        vm.stopPrank();

        // 50 GUGU * 0.08 = 4 USDT
        // Alice: started with 10000 USDT, paid 10, got back 4 = 9994
        assertEq(usdt.balanceOf(alice), 9994 * 1e18);
        assertEq(gugu.balanceOf(alice), 50 * 1e18);
    }

    function test_RevertSellWhenBuybackDisabled() public {
        vm.prank(alice);
        vm.expectRevert(TokenSwap.BuybackNotEnabled.selector);
        sale.sell(address(usdt), 100 * 1e18);
    }

    // ═══════════════════════════════════════════
    //              Admin Tests
    // ═══════════════════════════════════════════

    function test_SetTokenPrices() public {
        sale.setTokenPrices(address(usdt), 0.2 * 1e18, 0.15 * 1e18);

        (uint256 bp, uint256 sp, bool en) = sale.getPayTokenInfo(address(usdt));
        assertEq(bp, 0.2 * 1e18);
        assertEq(sp, 0.15 * 1e18);
        assertTrue(en);
    }

    function test_WithdrawToken_USDT() public {
        vm.startPrank(alice);
        usdt.approve(address(sale), 100 * 1e18);
        sale.buy(address(usdt), 100 * 1e18);
        vm.stopPrank();

        uint256 ownerBefore = usdt.balanceOf(owner);
        sale.withdrawToken(address(usdt), 100 * 1e18);
        assertEq(usdt.balanceOf(owner), ownerBefore + 100 * 1e18);
    }

    function test_WithdrawETH() public {
        vm.deal(address(sale), 1 ether);
        uint256 ownerBefore = owner.balance;
        sale.withdrawETH();
        assertEq(address(sale).balance, 0);
        assertEq(owner.balance, ownerBefore + 1 ether);
    }

    function test_PauseAndResume() public {
        sale.setPaused(true);
        assertTrue(sale.paused());

        sale.setPaused(false);
        assertFalse(sale.paused());

        vm.startPrank(alice);
        usdt.approve(address(sale), 10 * 1e18);
        sale.buy(address(usdt), 10 * 1e18);
        vm.stopPrank();

        assertEq(gugu.balanceOf(alice), 100 * 1e18);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {GUGUToken} from "../src/GUGUToken.sol";

contract GUGUTokenTest is Test {
    GUGUToken public token;
    address public owner = address(this);
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public minter = makeAddr("minter");

    uint256 public constant INITIAL_SUPPLY = 10_000_000 * 1e18;

    function setUp() public {
        token = new GUGUToken(INITIAL_SUPPLY);
    }

    // ── 基本信息 ──

    function test_Name() public view {
        assertEq(token.name(), "GUGU Token");
    }

    function test_Symbol() public view {
        assertEq(token.symbol(), "GUGU");
    }

    function test_InitialSupply() public view {
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
        assertEq(token.balanceOf(owner), INITIAL_SUPPLY);
    }

    // ── Minter 管理 ──

    function test_AddMinter() public {
        token.addMinter(minter);
        assertTrue(token.minters(minter));
    }

    function test_RemoveMinter() public {
        token.addMinter(minter);
        token.removeMinter(minter);
        assertFalse(token.minters(minter));
    }

    function test_RevertAddMinterNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        token.addMinter(minter);
    }

    // ── 铸造 ──

    function test_MinterCanMint() public {
        token.addMinter(minter);
        vm.prank(minter);
        token.mint(alice, 1000 * 1e18);
        assertEq(token.balanceOf(alice), 1000 * 1e18);
    }

    function test_RevertMintNotMinter() public {
        vm.prank(alice);
        vm.expectRevert();
        token.mint(alice, 1000);
    }

    // ── 销毁 ──

    function test_Burn() public {
        uint256 burnAmount = 100 * 1e18;
        token.burn(burnAmount);
        assertEq(token.balanceOf(owner), INITIAL_SUPPLY - burnAmount);
    }

    function test_BurnFrom() public {
        token.transfer(alice, 1000 * 1e18);
        vm.prank(alice);
        token.approve(owner, 500 * 1e18);
        token.burnFrom(alice, 500 * 1e18);
        assertEq(token.balanceOf(alice), 500 * 1e18);
    }
}

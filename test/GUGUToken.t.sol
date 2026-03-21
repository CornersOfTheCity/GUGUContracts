// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {GUGUToken} from "../src/GUGUToken.sol";

contract GUGUTokenTest is Test {
    GUGUToken public token;
    address public owner = address(this);
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    uint256 public constant INITIAL_SUPPLY = 10_000_000 * 1e18;

    function setUp() public {
        token = new GUGUToken(owner);
        token.mint(owner, INITIAL_SUPPLY);
    }

    // -- Basic Info --

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

    function test_MaxSupply() public view {
        assertEq(token.MAX_SUPPLY(), 100_000_000 * 1e18);
    }

    // -- Minting (Owner Only) --

    function test_OwnerCanMint() public {
        token.mint(alice, 1000 * 1e18);
        assertEq(token.balanceOf(alice), 1000 * 1e18);
    }

    function test_RevertMintNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        token.mint(alice, 1000);
    }

    function test_RevertMintExceedsMaxSupply() public {
        vm.expectRevert();
        token.mint(alice, 100_000_000 * 1e18); // Already have 10M, minting 100M exceeds cap
    }

    // -- Burning --

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

    // -- Blacklist --

    function test_AddBlacklist() public {
        token.addBlacklist(alice);
        assertTrue(token.blacklisted(alice));
    }

    function test_RemoveBlacklist() public {
        token.addBlacklist(alice);
        token.removeBlacklist(alice);
        assertFalse(token.blacklisted(alice));
    }

    function test_RevertTransferFromBlacklisted() public {
        token.transfer(alice, 1000 * 1e18);
        token.addBlacklist(alice);
        vm.prank(alice);
        vm.expectRevert();
        token.transfer(bob, 100 * 1e18);
    }

    function test_RevertTransferToBlacklisted() public {
        token.addBlacklist(bob);
        vm.expectRevert();
        token.transfer(bob, 100 * 1e18);
    }

    function test_RevertBlacklistNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        token.addBlacklist(bob);
    }
}

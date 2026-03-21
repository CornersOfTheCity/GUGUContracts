// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {GUGUNFT} from "../src/GUGUNFT.sol";

contract GUGUNFTTest is Test {
    GUGUNFT public nft;
    address public owner = address(this);
    address public alice = makeAddr("alice");
    address public minter = makeAddr("minter");

    receive() external payable {}

    function setUp() public {
        nft = new GUGUNFT(owner);
    }

    // -- Basic Info --

    function test_Name() public view {
        assertEq(nft.name(), "GUGU NFT");
        assertEq(nft.symbol(), "GUGUNFT");
    }



    function test_MintPrices() public view {
        assertEq(nft.mintPriceByRarity(GUGUNFT.Rarity.Founder), 0.25 ether);
        assertEq(nft.mintPriceByRarity(GUGUNFT.Rarity.Pro), 0.025 ether);
        assertEq(nft.mintPriceByRarity(GUGUNFT.Rarity.Basic), 0.0025 ether);
    }

    // -- Public Minting --

    function test_MintPublicBasic() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        nft.mintPublic{value: 0.0025 ether}(GUGUNFT.Rarity.Basic);

        assertEq(nft.balanceOf(alice), 1);
        assertEq(nft.ownerOf(1), alice);
        assertEq(uint256(nft.getRarity(1)), uint256(GUGUNFT.Rarity.Basic));
        assertEq(nft.totalSupplyByRarity(GUGUNFT.Rarity.Basic), 1);
    }

    function test_MintPublicFounder() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        nft.mintPublic{value: 0.25 ether}(GUGUNFT.Rarity.Founder);

        assertEq(nft.balanceOf(alice), 1);
        assertEq(uint256(nft.getRarity(1)), uint256(GUGUNFT.Rarity.Founder));
    }

    function test_RevertInsufficientPayment() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert();
        nft.mintPublic{value: 0.001 ether}(GUGUNFT.Rarity.Basic);
    }

    function test_RefundExcessPayment() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        nft.mintPublic{value: 0.25 ether}(GUGUNFT.Rarity.Basic); // Overpaid
        // Refund: 0.25 - 0.0025 = 0.2475 ether
        assertEq(alice.balance, 0.75 ether + 0.2475 ether);
    }



    // -- Authorized Minting --

    function test_MinterMint() public {
        nft.addMinter(minter);
        vm.prank(minter);
        uint256 tokenId = nft.mint(alice, GUGUNFT.Rarity.Pro);

        assertEq(tokenId, 1);
        assertEq(nft.ownerOf(1), alice);
        assertEq(uint256(nft.getRarity(1)), uint256(GUGUNFT.Rarity.Pro));
    }

    function test_RevertMintNotMinter() public {
        vm.prank(alice);
        vm.expectRevert();
        nft.mint(alice, GUGUNFT.Rarity.Basic);
    }

    // -- BaseURI --

    function test_SetBaseURI() public {
        nft.setBaseURI("https://api.gugu.io/nft/");
        nft.addMinter(minter);
        vm.prank(minter);
        nft.mint(alice, GUGUNFT.Rarity.Basic);
        assertEq(nft.tokenURI(1), "https://api.gugu.io/nft/1");
    }

    // -- Withdraw --

    function test_Withdraw() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        nft.mintPublic{value: 0.25 ether}(GUGUNFT.Rarity.Founder);

        uint256 ownerBalBefore = owner.balance;
        nft.withdraw();
        assertEq(owner.balance - ownerBalBefore, 0.25 ether);
    }
}

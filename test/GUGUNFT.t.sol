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
        nft = new GUGUNFT();
    }

    // ── 基本信息 ──

    function test_Name() public view {
        assertEq(nft.name(), "GUGU NFT");
        assertEq(nft.symbol(), "GUGUNFT");
    }

    function test_MaxSupply() public view {
        assertEq(nft.maxSupplyByRarity(GUGUNFT.Rarity.Founder), 100);
        assertEq(nft.maxSupplyByRarity(GUGUNFT.Rarity.Pro), 500);
        assertEq(nft.maxSupplyByRarity(GUGUNFT.Rarity.Basic), 2000);
    }

    function test_MintPrices() public view {
        assertEq(nft.mintPriceByRarity(GUGUNFT.Rarity.Founder), 0.5 ether);
        assertEq(nft.mintPriceByRarity(GUGUNFT.Rarity.Pro), 0.1 ether);
        assertEq(nft.mintPriceByRarity(GUGUNFT.Rarity.Basic), 0.02 ether);
    }

    // ── 公开铸造 ──

    function test_MintPublicBasic() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        nft.mintPublic{value: 0.02 ether}(GUGUNFT.Rarity.Basic);

        assertEq(nft.balanceOf(alice), 1);
        assertEq(nft.ownerOf(1), alice);
        assertEq(uint256(nft.getRarity(1)), uint256(GUGUNFT.Rarity.Basic));
        assertEq(nft.totalSupplyByRarity(GUGUNFT.Rarity.Basic), 1);
    }

    function test_MintPublicFounder() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        nft.mintPublic{value: 0.5 ether}(GUGUNFT.Rarity.Founder);

        assertEq(nft.balanceOf(alice), 1);
        assertEq(uint256(nft.getRarity(1)), uint256(GUGUNFT.Rarity.Founder));
    }

    function test_RevertInsufficientPayment() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert();
        nft.mintPublic{value: 0.01 ether}(GUGUNFT.Rarity.Basic);
    }

    function test_RefundExcessPayment() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        nft.mintPublic{value: 0.5 ether}(GUGUNFT.Rarity.Basic); // 多付
        // 退还 0.5 - 0.02 = 0.48 ether
        assertEq(alice.balance, 0.98 ether);
    }

    function test_RevertExceedsMaxSupply() public {
        vm.deal(alice, 300 ether);
        vm.startPrank(alice);
        // Basic 最大 2000, 先铸 2000 个, 这里我们只测几个然后mock
        vm.stopPrank();

        // 通过 Minter 铸造到上限
        nft.addMinter(minter);
        vm.startPrank(minter);
        for (uint256 i = 0; i < 100; i++) {
            nft.mint(alice, GUGUNFT.Rarity.Founder);
        }
        vm.expectRevert();
        nft.mint(alice, GUGUNFT.Rarity.Founder); // 第 101 个
        vm.stopPrank();
    }

    // ── 授权铸造 ──

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

    // ── BaseURI ──

    function test_SetBaseURI() public {
        nft.setBaseURI("https://api.gugu.io/nft/");
        nft.addMinter(minter);
        vm.prank(minter);
        nft.mint(alice, GUGUNFT.Rarity.Basic);
        assertEq(nft.tokenURI(1), "https://api.gugu.io/nft/1");
    }

    // ── Withdraw ──

    function test_Withdraw() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        nft.mintPublic{value: 0.5 ether}(GUGUNFT.Rarity.Founder);

        uint256 ownerBalBefore = owner.balance;
        nft.withdraw();
        assertEq(owner.balance - ownerBalBefore, 0.5 ether);
    }
}

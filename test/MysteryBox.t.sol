// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {GUGUToken} from "../src/GUGUToken.sol";
import {GUGUNFT} from "../src/GUGUNFT.sol";
import {MysteryBox} from "../src/MysteryBox.sol";
import {VRFCoordinatorV2_5Mock} from
    "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";

contract MysteryBoxTest is Test {
    GUGUToken public token;
    GUGUNFT public nft;
    MysteryBox public mysteryBox;
    VRFCoordinatorV2_5Mock public vrfCoordinator;

    address public owner = address(this);
    address public alice = makeAddr("alice");

    uint256 public subId;
    bytes32 public constant KEY_HASH = bytes32(uint256(1));

    function setUp() public {
        // Deploy VRF Mock (low fees for testing)
        vrfCoordinator = new VRFCoordinatorV2_5Mock(
            0.001 ether,    // baseFee
            0.000001 ether, // gasPriceLink
            1e18            // weiPerUnitLink (1 LINK = 1 ETH)
        );

        // Create subscription and fund it
        subId = vrfCoordinator.createSubscription();
        vrfCoordinator.fundSubscription(subId, 10_000_000 ether);

        // Deploy contracts
        token = new GUGUToken(owner);
        token.mint(owner, 10_000_000 * 1e18);
        nft = new GUGUNFT(owner);
        mysteryBox = new MysteryBox(
            address(token),
            address(nft),
            address(vrfCoordinator),
            subId,
            KEY_HASH
        );

        // Configure permissions
        nft.addMinter(address(mysteryBox));

        // Register consumer
        vrfCoordinator.addConsumer(subId, address(mysteryBox));

        // Give alice some tokens
        token.transfer(alice, 10000 * 1e18);
    }

    // -- Dynamic Pricing --

    function test_InitialPrice() public view {
        // tier=0, price = 100 * (2+0) / 2 = 100 GUGU
        assertEq(mysteryBox.currentBoxPrice(), 100 * 1e18);
    }

    function test_DefaultBaseAndMax() public view {
        assertEq(mysteryBox.basePrice(), 100 * 1e18);
        assertEq(mysteryBox.maxPrice(), 500 * 1e18);
    }

    // -- Purchasing --

    function test_BuyBox() public {
        uint256 price = mysteryBox.currentBoxPrice(); // 100 GUGU

        vm.startPrank(alice);
        token.approve(address(mysteryBox), price);
        mysteryBox.buyBox(1);
        vm.stopPrank();

        // Tokens are burned
        assertEq(token.balanceOf(alice), 10000 * 1e18 - price);

        // There should be one pending request
        uint256[] memory ids = mysteryBox.getRequestIds();
        assertEq(ids.length, 1);

        (bool fulfilled,) = mysteryBox.getRequestStatus(ids[0]);
        assertFalse(fulfilled);
    }

    function test_BuyBoxBatch() public {
        uint256 price = mysteryBox.currentBoxPrice();

        vm.startPrank(alice);
        token.approve(address(mysteryBox), price * 5);
        mysteryBox.buyBox(5);
        vm.stopPrank();

        assertEq(token.balanceOf(alice), 10000 * 1e18 - price * 5);
    }

    function test_RevertBuyBoxZeroQuantity() public {
        vm.prank(alice);
        vm.expectRevert();
        mysteryBox.buyBox(0);
    }

    function test_RevertBuyBoxTooMany() public {
        vm.prank(alice);
        vm.expectRevert();
        mysteryBox.buyBox(6);
    }

    // -- VRF Callback --

    function test_FulfillRandomWords() public {
        uint256 price = mysteryBox.currentBoxPrice();

        vm.startPrank(alice);
        token.approve(address(mysteryBox), price);
        mysteryBox.buyBox(1);
        vm.stopPrank();

        uint256[] memory ids = mysteryBox.getRequestIds();

        // Mock VRF callback
        vrfCoordinator.fulfillRandomWords(ids[0], address(mysteryBox));

        // Request should be fulfilled
        (bool fulfilled,) = mysteryBox.getRequestStatus(ids[0]);
        assertTrue(fulfilled);

        // Alice should have received one NFT
        assertEq(nft.balanceOf(alice), 1);

        // totalBoxOpened should be incremented
        assertEq(mysteryBox.totalBoxOpened(), 1);
    }

    function test_FulfillMultipleBoxes() public {
        uint256 price = mysteryBox.currentBoxPrice();

        vm.startPrank(alice);
        token.approve(address(mysteryBox), price * 3);
        mysteryBox.buyBox(3);
        vm.stopPrank();

        uint256[] memory ids = mysteryBox.getRequestIds();
        vrfCoordinator.fulfillRandomWords(ids[0], address(mysteryBox));

        assertEq(nft.balanceOf(alice), 3);
        assertEq(mysteryBox.totalBoxOpened(), 3);
    }

    // -- Management --

    function test_SetBasePrice() public {
        mysteryBox.setBasePrice(200 * 1e18);
        assertEq(mysteryBox.basePrice(), 200 * 1e18);
        // tier=0: price = 200 * (2+0) / 2 = 200
        assertEq(mysteryBox.currentBoxPrice(), 200 * 1e18);
    }

    function test_SetMaxPrice() public {
        mysteryBox.setMaxPrice(300 * 1e18);
        assertEq(mysteryBox.maxPrice(), 300 * 1e18);
    }

    function test_PriceCapAtMax() public {
        // Set a low max to test cap
        mysteryBox.setMaxPrice(120 * 1e18);
        // tier=0: price = 100, < 120 → 100
        assertEq(mysteryBox.currentBoxPrice(), 100 * 1e18);

        mysteryBox.setMaxPrice(90 * 1e18);
        // tier=0: price = 100, > 90 → capped at 90
        assertEq(mysteryBox.currentBoxPrice(), 90 * 1e18);
    }

    function test_SetProbabilities() public {
        uint256[3] memory probs = [uint256(1000), uint256(3000), uint256(6000)];
        mysteryBox.setProbabilities(probs);
        assertEq(mysteryBox.probabilities(0), 1000);
        assertEq(mysteryBox.probabilities(1), 3000);
        assertEq(mysteryBox.probabilities(2), 6000);
    }

    function test_RevertInvalidProbabilities() public {
        uint256[3] memory probs = [uint256(1000), uint256(3000), uint256(5000)];
        vm.expectRevert();
        mysteryBox.setProbabilities(probs); // sum = 9000, not 10000
    }
}

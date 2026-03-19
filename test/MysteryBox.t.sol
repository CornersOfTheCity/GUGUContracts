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
        // 部署 VRF Mock (低费用用于测试)
        vrfCoordinator = new VRFCoordinatorV2_5Mock(
            0.001 ether,    // baseFee
            0.000001 ether, // gasPriceLink
            1e18            // weiPerUnitLink (1 LINK = 1 ETH)
        );

        // 创建 subscription 并充值
        subId = vrfCoordinator.createSubscription();
        vrfCoordinator.fundSubscription(subId, 10_000_000 ether);

        // 部署合约
        token = new GUGUToken(10_000_000 * 1e18);
        nft = new GUGUNFT();
        mysteryBox = new MysteryBox(
            address(token),
            address(nft),
            address(vrfCoordinator),
            subId,
            KEY_HASH
        );

        // 配置权限
        nft.addMinter(address(mysteryBox));

        // 注册 consumer
        vrfCoordinator.addConsumer(subId, address(mysteryBox));

        // 给 alice 一些 Token
        token.transfer(alice, 10000 * 1e18);
    }

    // ── 购买 ──

    function test_BuyBox() public {
        vm.startPrank(alice);
        token.approve(address(mysteryBox), 100 * 1e18);
        mysteryBox.buyBox(1);
        vm.stopPrank();

        // Token 被 burn
        assertEq(token.balanceOf(alice), 9900 * 1e18);

        // 有一个 pending request
        uint256[] memory ids = mysteryBox.getRequestIds();
        assertEq(ids.length, 1);

        (bool fulfilled,) = mysteryBox.getRequestStatus(ids[0]);
        assertFalse(fulfilled);
    }

    function test_BuyBoxBatch() public {
        vm.startPrank(alice);
        token.approve(address(mysteryBox), 500 * 1e18);
        mysteryBox.buyBox(5);
        vm.stopPrank();

        assertEq(token.balanceOf(alice), 9500 * 1e18);
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

    // ── VRF 回调 ──

    function test_FulfillRandomWords() public {
        vm.startPrank(alice);
        token.approve(address(mysteryBox), 100 * 1e18);
        mysteryBox.buyBox(1);
        vm.stopPrank();

        uint256[] memory ids = mysteryBox.getRequestIds();

        // Mock VRF 回调
        vrfCoordinator.fulfillRandomWords(ids[0], address(mysteryBox));

        // 请求已完成
        (bool fulfilled,) = mysteryBox.getRequestStatus(ids[0]);
        assertTrue(fulfilled);

        // Alice 应该获得一个 NFT
        assertEq(nft.balanceOf(alice), 1);
    }

    function test_FulfillMultipleBoxes() public {
        vm.startPrank(alice);
        token.approve(address(mysteryBox), 300 * 1e18);
        mysteryBox.buyBox(3);
        vm.stopPrank();

        uint256[] memory ids = mysteryBox.getRequestIds();
        vrfCoordinator.fulfillRandomWords(ids[0], address(mysteryBox));

        assertEq(nft.balanceOf(alice), 3);
    }

    // ── 管理 ──

    function test_SetBoxPrice() public {
        mysteryBox.setBoxPrice(200 * 1e18);
        assertEq(mysteryBox.boxPrice(), 200 * 1e18);
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

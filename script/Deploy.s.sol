// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {GUGUToken} from "../src/GUGUToken.sol";
import {GUGUNFT} from "../src/GUGUNFT.sol";
import {NFTStaking} from "../src/NFTStaking.sol";
import {MysteryBox} from "../src/MysteryBox.sol";
import {TokenSwap} from "../src/TokenSwap.sol";

/**
 * @title Deploy
 * @notice 部署全部 GUGU DeFi 合约并配置权限
 *
 * 使用方式:
 *   forge script script/Deploy.s.sol:Deploy \
 *     --rpc-url $RPC_URL \
 *     --private-key $PRIVATE_KEY \
 *     --broadcast
 *
 * 环境变量:
 *   INITIAL_SUPPLY      - 初始 Token 供应量 (默认 10_000_000 * 1e18)
 *   VRF_COORDINATOR     - Chainlink VRF Coordinator 地址
 *   VRF_SUBSCRIPTION_ID - Chainlink VRF Subscription ID
 *   VRF_KEY_HASH        - Chainlink VRF Key Hash
 */
contract Deploy is Script {
    function run() external {
        uint256 initialSupply = vm.envOr("INITIAL_SUPPLY", uint256(10_000_000 * 1e18));
        address vrfCoordinator = vm.envAddress("VRF_COORDINATOR");
        uint256 subscriptionId = vm.envUint("VRF_SUBSCRIPTION_ID");
        bytes32 keyHash = vm.envBytes32("VRF_KEY_HASH");

        vm.startBroadcast();

        // 1. 部署 GUGUToken
        GUGUToken token = new GUGUToken(initialSupply);
        console.log("GUGUToken deployed at:", address(token));

        // 2. 部署 GUGUNFT
        GUGUNFT nft = new GUGUNFT();
        console.log("GUGUNFT deployed at:", address(nft));

        // 3. 部署 NFTStaking
        NFTStaking staking = new NFTStaking(address(token), address(nft));
        console.log("NFTStaking deployed at:", address(staking));

        // 4. 部署 MysteryBox
        MysteryBox mysteryBox = new MysteryBox(
            address(token),
            address(nft),
            vrfCoordinator,
            subscriptionId,
            keyHash
        );
        console.log("MysteryBox deployed at:", address(mysteryBox));

        // 5. 部署 TokenSwap
        TokenSwap tokenSwap = new TokenSwap();
        console.log("TokenSwap deployed at:", address(tokenSwap));

        // 6. 配置权限
        // Staking 合约可以铸造 Token (奖励)
        token.addMinter(address(staking));
        console.log("NFTStaking authorized as Token minter");

        // MysteryBox 合约可以铸造 NFT
        nft.addMinter(address(mysteryBox));
        console.log("MysteryBox authorized as NFT minter");

        vm.stopBroadcast();

        // 提示手动步骤
        console.log("========================================");
        console.log("Deployment complete! Manual steps:");
        console.log("1. Add MysteryBox as VRF consumer in Chainlink subscription");
        console.log("2. Add liquidity to TokenSwap if needed");
        console.log("========================================");
    }
}

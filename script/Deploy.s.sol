// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {GUGUToken} from "../src/GUGUToken.sol";
import {GUGUNFT} from "../src/GUGUNFT.sol";
import {NFTStaking} from "../src/NFTStaking.sol";
import {MysteryBox} from "../src/MysteryBox.sol";
import {TokenSwap} from "../src/TokenSwap.sol";
import {Airdrop} from "../src/Airdrop.sol";

/**
 * @title Deploy
 * @notice Deploy all GUGU DeFi contracts, configure permissions, and distribute tokens per Tokenomics
 *
 * Usage:
 *   forge script script/Deploy.s.sol:Deploy \
 *     --rpc-url $RPC_URL \
 *     --private-key $PRIVATE_KEY \
 *     --broadcast
 *
 * Environment Variables:
 *   VRF_COORDINATOR     - Chainlink VRF Coordinator address
 *   VRF_SUBSCRIPTION_ID - Chainlink VRF Subscription ID
 *   VRF_KEY_HASH        - Chainlink VRF Key Hash
 *   TEAM_WALLET         - Team wallet address (defaults to deployer)
 *   RESERVE_WALLET      - Reserve wallet address (defaults to deployer)
 *
 * Tokenomics (Total Supply: 100 Million):
 *   - Uniswap Liquidity Pool: 30,000,000 (30%) -> Stays in deployer, manually add liquidity later
 *   - NFT Staking Rewards:    40,000,000 (40%) -> Transferred to Staking contract as pre-funded pool
 *   - Team:                   15,000,000 (15%) -> Transferred to team wallet
 *   - Mystery Box Operations: 10,000,000 (10%) -> Consumed via MysteryBox burn mechanism
 *   - Reserve:                 5,000,000 (5%)  -> Transferred to reserve wallet
 */
contract Deploy is Script {
    // -- Token Allocation Constants --
    uint256 constant TOTAL_SUPPLY   = 100_000_000 * 1e18; // 100 million
    uint256 constant UNISWAP_POOL   =  30_000_000 * 1e18; // 30 million
    uint256 constant STAKING_REWARD =  40_000_000 * 1e18; // 40 million (pre-funded pool)
    uint256 constant TEAM_ALLOC     =  15_000_000 * 1e18; // 15 million
    uint256 constant BOX_OPERATION  =  10_000_000 * 1e18; // 10 million
    uint256 constant RESERVE        =   5_000_000 * 1e18; //  5 million

    function run() external {
        address vrfCoordinator = vm.envAddress("VRF_COORDINATOR");
        uint256 subscriptionId = vm.envUint("VRF_SUBSCRIPTION_ID");
        bytes32 keyHash = vm.envBytes32("VRF_KEY_HASH");
        address initialOwner = vm.envOr("INITIAL_OWNER", msg.sender);
        address teamWallet = vm.envOr("TEAM_WALLET", msg.sender);
        address reserveWallet = vm.envOr("RESERVE_WALLET", msg.sender);

        vm.startBroadcast();

        // =======================================
        //          1. Deploy Contracts
        // =======================================

        GUGUToken token = new GUGUToken(initialOwner);
        console.log("GUGUToken deployed at:", address(token));

        // GUGUNFT 先用部署者做临时 Owner（需要 addMinter 权限）
        GUGUNFT nft = new GUGUNFT(msg.sender);
        console.log("GUGUNFT deployed at:", address(nft));

        NFTStaking staking = new NFTStaking(initialOwner, address(token), address(nft));
        console.log("NFTStaking deployed at:", address(staking));

        MysteryBox mysteryBox = new MysteryBox(
            address(token),
            address(nft),
            vrfCoordinator,
            subscriptionId,
            keyHash
        );
        console.log("MysteryBox deployed at:", address(mysteryBox));

        // TokenSwap: set PAY_TOKEN (stablecoin address) and initial price
        address payToken = vm.envAddress("PAY_TOKEN");
        uint256 salePrice = vm.envOr("SALE_PRICE", uint256(0.1 * 1e18)); // default: 1 GUGU = 0.1 USDT
        TokenSwap tokenSwap = new TokenSwap(address(token), payToken, salePrice, initialOwner);
        console.log("TokenSwap deployed at:", address(tokenSwap));

        Airdrop airdrop = new Airdrop(initialOwner, address(nft));
        console.log("Airdrop deployed at:", address(airdrop));

        // =======================================
        //          2. Configure NFT Minters
        // =======================================

        nft.addMinter(address(mysteryBox));
        console.log("MysteryBox authorized as NFT minter");

        nft.addMinter(address(airdrop));
        console.log("Airdrop authorized as NFT minter");

        // 转移 NFT 合约 Ownership 给 INITIAL_OWNER
        if (initialOwner != msg.sender) {
            nft.transferOwnership(initialOwner);
            console.log("GUGUNFT ownership transferred to:", initialOwner);
        }

        vm.stopBroadcast();

        // =======================================
        //          4. Post-Deployment Steps
        // =======================================
        console.log("========================================");
        console.log("Deployment complete!");
        console.log("========================================");
        console.log("");
        console.log("Token Distribution:");
        console.log("  Uniswap Pool:    30,000,000 GUGU (in deployer)");
        console.log("  Staking Rewards: 40,000,000 GUGU (in Staking contract)");
        console.log("  Team:            15,000,000 GUGU");
        console.log("  Mystery Box:     10,000,000 GUGU (in deployer)");
        console.log("  Reserve:          5,000,000 GUGU");
        console.log("");
        console.log("Manual steps:");
        console.log("  1. Add MysteryBox as VRF consumer in Chainlink subscription");
        console.log("  2. Add 30M GUGU + ETH to Uniswap liquidity pool");
        console.log("  3. Transfer 10M GUGU to MysteryBox or let users burn via buyBox");
        console.log("  4. Update frontend contract addresses in contracts.js");
        console.log("========================================");
    }
}

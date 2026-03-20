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
 * @notice 部署全部 GUGU DeFi 合约，配置权限，并按 Tokenomics 分配代币
 *
 * 使用方式:
 *   forge script script/Deploy.s.sol:Deploy \
 *     --rpc-url $RPC_URL \
 *     --private-key $PRIVATE_KEY \
 *     --broadcast
 *
 * 环境变量:
 *   VRF_COORDINATOR     - Chainlink VRF Coordinator 地址
 *   VRF_SUBSCRIPTION_ID - Chainlink VRF Subscription ID
 *   VRF_KEY_HASH        - Chainlink VRF Key Hash
 *   TEAM_WALLET         - 团队钱包地址 (默认 deployer)
 *   RESERVE_WALLET      - 预留钱包地址 (默认 deployer)
 *
 * Tokenomics (总量 1 亿):
 *   - Uniswap 流动性池: 3,000 万 (30%) → 留在 deployer, 后续手动添加流动性
 *   - NFT 质押产出:     4,000 万 (40%) → 由 Staking 合约通过 Minter 逐步铸造
 *   - 团队持有:         1,500 万 (15%) → 转入团队钱包
 *   - 盲盒运营:         1,000 万 (10%) → 由 MysteryBox 合约通过 burn 消耗
 *   - 预留:               500 万 (5%)  → 转入预留钱包
 */
contract Deploy is Script {
    // ── Token 分配常量 ──
    uint256 constant TOTAL_SUPPLY   = 100_000_000 * 1e18; // 1 亿
    uint256 constant UNISWAP_POOL   =  30_000_000 * 1e18; // 3000 万
    uint256 constant STAKING_REWARD =  40_000_000 * 1e18; // 4000 万 (Minter 逐步铸)
    uint256 constant TEAM_ALLOC     =  15_000_000 * 1e18; // 1500 万
    uint256 constant BOX_OPERATION  =  10_000_000 * 1e18; // 1000 万
    uint256 constant RESERVE        =   5_000_000 * 1e18; //  500 万

    function run() external {
        address vrfCoordinator = vm.envAddress("VRF_COORDINATOR");
        uint256 subscriptionId = vm.envUint("VRF_SUBSCRIPTION_ID");
        bytes32 keyHash = vm.envBytes32("VRF_KEY_HASH");
        address teamWallet = vm.envOr("TEAM_WALLET", msg.sender);
        address reserveWallet = vm.envOr("RESERVE_WALLET", msg.sender);

        // 初始铸造 = 全部 1 亿（质押奖励现在是预充值模式，需要预铸）
        uint256 initialMint = TOTAL_SUPPLY;

        vm.startBroadcast();

        // ═══════════════════════════════════════
        //          1. 部署合约
        // ═══════════════════════════════════════

        GUGUToken token = new GUGUToken(initialMint);
        console.log("GUGUToken deployed at:", address(token));
        console.log("  Initial mint:", initialMint / 1e18, "GUGU");

        GUGUNFT nft = new GUGUNFT();
        console.log("GUGUNFT deployed at:", address(nft));

        NFTStaking staking = new NFTStaking(address(token), address(nft));
        console.log("NFTStaking deployed at:", address(staking));

        MysteryBox mysteryBox = new MysteryBox(
            address(token),
            address(nft),
            vrfCoordinator,
            subscriptionId,
            keyHash
        );
        console.log("MysteryBox deployed at:", address(mysteryBox));

        TokenSwap tokenSwap = new TokenSwap();
        console.log("TokenSwap deployed at:", address(tokenSwap));

        Airdrop airdrop = new Airdrop(address(nft));
        console.log("Airdrop deployed at:", address(airdrop));

        // ═══════════════════════════════════════
        //          2. 配置权限
        // ═══════════════════════════════════════

        // MysteryBox 合约可以铸造 NFT
        nft.addMinter(address(mysteryBox));
        console.log("MysteryBox authorized as NFT minter");

        // Airdrop 合约可以铸造 NFT
        nft.addMinter(address(airdrop));
        console.log("Airdrop authorized as NFT minter");

        // ═══════════════════════════════════════
        //          3. 代币分配
        // ═══════════════════════════════════════

        // 质押奖励 4000 万 → 转入 Staking 合约
        token.transfer(address(staking), STAKING_REWARD);
        console.log("Staking reward pool funded:", STAKING_REWARD / 1e18, "GUGU");

        // 团队持有 1500 万
        if (teamWallet != msg.sender) {
            token.transfer(teamWallet, TEAM_ALLOC);
            console.log("Team allocation transferred:", TEAM_ALLOC / 1e18, "GUGU");
        }

        // 预留 500 万
        if (reserveWallet != msg.sender && reserveWallet != teamWallet) {
            token.transfer(reserveWallet, RESERVE);
            console.log("Reserve allocation transferred:", RESERVE / 1e18, "GUGU");
        }

        // Uniswap 池子 3000 万 和 盲盒运营 1000 万 暂时留在 deployer
        // 后续手动:
        //   - 将 3000 万 添加到 Uniswap/DEX 流动性池
        //   - 盲盒消耗由用户 approve → MysteryBox.buyBox() → burn

        vm.stopBroadcast();

        // ═══════════════════════════════════════
        //          4. 部署后手动步骤
        // ═══════════════════════════════════════
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

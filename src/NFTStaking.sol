// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {GUGUNFT} from "./GUGUNFT.sol";
import {GUGUToken} from "./GUGUToken.sol";

/**
 * @title NFTStaking
 * @notice 质押 GUGUNFT 获取 GUGUToken 奖励
 *         - Founder: 50 GUGU/天
 *         - Pro:     15 GUGU/天
 *         - Basic:    3 GUGU/天
 */
contract NFTStaking is IERC721Receiver, Ownable, ReentrancyGuard {
    GUGUToken public immutable guguToken;
    GUGUNFT public immutable guguNFT;

    /// @notice 每种稀有度的每日奖励 (含精度 1e18)
    mapping(GUGUNFT.Rarity => uint256) public dailyReward;

    /// @notice 质押信息
    struct StakeInfo {
        address owner;
        uint256 stakedAt;
        uint256 lastClaimedAt;
    }

    /// @notice tokenId => 质押信息
    mapping(uint256 => StakeInfo) public stakes;

    /// @notice 用户 => 质押的 tokenId 列表
    mapping(address => uint256[]) private _userStakedTokens;

    /// @notice tokenId 在用户数组中的索引
    mapping(uint256 => uint256) private _tokenIndexInUser;

    // ── Events ──
    event Staked(address indexed user, uint256 indexed tokenId, GUGUNFT.Rarity rarity);
    event Unstaked(address indexed user, uint256 indexed tokenId, uint256 reward);
    event RewardsClaimed(address indexed user, uint256 reward);
    event DailyRewardUpdated(GUGUNFT.Rarity rarity, uint256 rewardPerDay);

    // ── Errors ──
    error NotStakeOwner(uint256 tokenId);
    error TokenNotStaked(uint256 tokenId);

    constructor(address _guguToken, address _guguNFT) Ownable(msg.sender) {
        guguToken = GUGUToken(_guguToken);
        guguNFT = GUGUNFT(_guguNFT);

        // 默认每日奖励 (含 18 位精度)
        dailyReward[GUGUNFT.Rarity.Founder] = 50 * 1e18;
        dailyReward[GUGUNFT.Rarity.Pro] = 15 * 1e18;
        dailyReward[GUGUNFT.Rarity.Basic] = 3 * 1e18;
    }

    // ═══════════════════════════════════════════
    //                质押
    // ═══════════════════════════════════════════

    /// @notice 质押单个 NFT
    function stake(uint256 tokenId) external nonReentrant {
        guguNFT.transferFrom(msg.sender, address(this), tokenId);

        stakes[tokenId] = StakeInfo({
            owner: msg.sender,
            stakedAt: block.timestamp,
            lastClaimedAt: block.timestamp
        });

        // 加入用户列表
        _tokenIndexInUser[tokenId] = _userStakedTokens[msg.sender].length;
        _userStakedTokens[msg.sender].push(tokenId);

        GUGUNFT.Rarity rarity = guguNFT.getRarity(tokenId);
        emit Staked(msg.sender, tokenId, rarity);
    }

    /// @notice 批量质押
    function stakeBatch(uint256[] calldata tokenIds) external nonReentrant {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            guguNFT.transferFrom(msg.sender, address(this), tokenId);

            stakes[tokenId] = StakeInfo({
                owner: msg.sender,
                stakedAt: block.timestamp,
                lastClaimedAt: block.timestamp
            });

            _tokenIndexInUser[tokenId] = _userStakedTokens[msg.sender].length;
            _userStakedTokens[msg.sender].push(tokenId);

            GUGUNFT.Rarity rarity = guguNFT.getRarity(tokenId);
            emit Staked(msg.sender, tokenId, rarity);
        }
    }

    // ═══════════════════════════════════════════
    //              取消质押
    // ═══════════════════════════════════════════

    /// @notice 取消质押，领取所有累积奖励
    function unstake(uint256 tokenId) external nonReentrant {
        StakeInfo storage info = stakes[tokenId];
        if (info.owner != msg.sender) revert NotStakeOwner(tokenId);

        uint256 reward = _calculateReward(tokenId);

        // 从用户列表中移除
        _removeFromUserList(msg.sender, tokenId);
        delete stakes[tokenId];

        // 先归还 NFT
        guguNFT.transferFrom(address(this), msg.sender, tokenId);

        // 再发放奖励
        if (reward > 0) {
            guguToken.mint(msg.sender, reward);
        }

        emit Unstaked(msg.sender, tokenId, reward);
    }

    /// @notice 批量取消质押
    function unstakeBatch(uint256[] calldata tokenIds) external nonReentrant {
        uint256 totalReward = 0;

        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            StakeInfo storage info = stakes[tokenId];
            if (info.owner != msg.sender) revert NotStakeOwner(tokenId);

            totalReward += _calculateReward(tokenId);
            _removeFromUserList(msg.sender, tokenId);
            delete stakes[tokenId];
            guguNFT.transferFrom(address(this), msg.sender, tokenId);

            emit Unstaked(msg.sender, tokenId, 0);
        }

        if (totalReward > 0) {
            guguToken.mint(msg.sender, totalReward);
        }
    }

    // ═══════════════════════════════════════════
    //              领取奖励
    // ═══════════════════════════════════════════

    /// @notice 领取所有已质押 NFT 的累积奖励
    function claimRewards() external nonReentrant {
        uint256[] storage tokenIds = _userStakedTokens[msg.sender];
        uint256 totalReward = 0;

        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            totalReward += _calculateReward(tokenId);
            stakes[tokenId].lastClaimedAt = block.timestamp;
        }

        if (totalReward > 0) {
            guguToken.mint(msg.sender, totalReward);
        }

        emit RewardsClaimed(msg.sender, totalReward);
    }

    // ═══════════════════════════════════════════
    //                查询
    // ═══════════════════════════════════════════

    /// @notice 查看用户待领取的总奖励
    function pendingRewards(address user) external view returns (uint256) {
        uint256[] storage tokenIds = _userStakedTokens[user];
        uint256 totalReward = 0;

        for (uint256 i = 0; i < tokenIds.length; i++) {
            totalReward += _calculateReward(tokenIds[i]);
        }

        return totalReward;
    }

    /// @notice 查看用户已质押的所有 tokenId
    function stakedTokensOf(address user) external view returns (uint256[] memory) {
        return _userStakedTokens[user];
    }

    /// @notice 查看用户已质押的 NFT 数量
    function stakedCountOf(address user) external view returns (uint256) {
        return _userStakedTokens[user].length;
    }

    // ═══════════════════════════════════════════
    //              Owner 管理
    // ═══════════════════════════════════════════

    /// @notice 设置某种稀有度的每日奖励
    function setDailyReward(GUGUNFT.Rarity rarity, uint256 rewardPerDay) external onlyOwner {
        dailyReward[rarity] = rewardPerDay;
        emit DailyRewardUpdated(rarity, rewardPerDay);
    }

    // ═══════════════════════════════════════════
    //              内部方法
    // ═══════════════════════════════════════════

    function _calculateReward(uint256 tokenId) internal view returns (uint256) {
        StakeInfo storage info = stakes[tokenId];
        if (info.owner == address(0)) return 0;

        GUGUNFT.Rarity rarity = guguNFT.getRarity(tokenId);
        uint256 elapsed = block.timestamp - info.lastClaimedAt;
        // dailyReward 已含 1e18 精度，除以 1 天的秒数
        return (elapsed * dailyReward[rarity]) / 1 days;
    }

    function _removeFromUserList(address user, uint256 tokenId) internal {
        uint256 index = _tokenIndexInUser[tokenId];
        uint256 lastIndex = _userStakedTokens[user].length - 1;

        if (index != lastIndex) {
            uint256 lastTokenId = _userStakedTokens[user][lastIndex];
            _userStakedTokens[user][index] = lastTokenId;
            _tokenIndexInUser[lastTokenId] = index;
        }

        _userStakedTokens[user].pop();
        delete _tokenIndexInUser[tokenId];
    }

    /// @notice ERC721Receiver
    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

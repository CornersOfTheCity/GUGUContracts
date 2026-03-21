// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {GUGUNFT} from "./GUGUNFT.sol";
import {GUGUToken} from "./GUGUToken.sol";

/**
 * @title NFTStaking
 * @notice Stake GUGUNFT to earn GUGUToken rewards (distributed from pre-funded token pool)
 *         - Founder: 50 GUGU/day
 *         - Pro:     15 GUGU/day
 *         - Basic:    3 GUGU/day
 */
contract NFTStaking is IERC721Receiver, Ownable, ReentrancyGuard {
    GUGUToken public immutable guguToken;
    GUGUNFT public immutable guguNFT;

    /// @notice Daily reward per rarity (with 1e18 precision)
    mapping(GUGUNFT.Rarity => uint256) public dailyReward;

    /// @notice Staking information
    struct StakeInfo {
        address owner;
        uint256 stakedAt;
        uint256 lastClaimedAt;
    }

    /// @notice tokenId => staking information
    mapping(uint256 => StakeInfo) public stakes;

    /// @notice user => list of staked tokenIds
    mapping(address => uint256[]) private _userStakedTokens;

    /// @notice tokenId index in user's staked array
    mapping(uint256 => uint256) private _tokenIndexInUser;

    // ── Events ──
    event Staked(address indexed user, uint256 indexed tokenId, GUGUNFT.Rarity rarity);
    event Unstaked(address indexed user, uint256 indexed tokenId, uint256 reward);
    event RewardsClaimed(address indexed user, uint256 reward);
    event DailyRewardUpdated(GUGUNFT.Rarity rarity, uint256 rewardPerDay);

    // ── Errors ──
    error NotStakeOwner(uint256 tokenId);
    error TokenNotStaked(uint256 tokenId);

    constructor(address initialOwner, address _guguToken, address _guguNFT) Ownable(initialOwner) {
        guguToken = GUGUToken(_guguToken);
        guguNFT = GUGUNFT(_guguNFT);

        // Default daily rewards (with 18 decimals precision)
        dailyReward[GUGUNFT.Rarity.Founder] = 50 * 1e18;
        dailyReward[GUGUNFT.Rarity.Pro] = 15 * 1e18;
        dailyReward[GUGUNFT.Rarity.Basic] = 3 * 1e18;
    }

    // ═══════════════════════════════════════════
    //                Staking
    // ═══════════════════════════════════════════

    /// @notice Stake a single NFT
    function stake(uint256 tokenId) external nonReentrant {
        guguNFT.transferFrom(msg.sender, address(this), tokenId);

        stakes[tokenId] = StakeInfo({
            owner: msg.sender,
            stakedAt: block.timestamp,
            lastClaimedAt: block.timestamp
        });

        // Add to user's staked list
        _tokenIndexInUser[tokenId] = _userStakedTokens[msg.sender].length;
        _userStakedTokens[msg.sender].push(tokenId);

        GUGUNFT.Rarity rarity = guguNFT.getRarity(tokenId);
        emit Staked(msg.sender, tokenId, rarity);
    }

    /// @notice Batch stake multiple NFTs
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
    //              Unstaking
    // ═══════════════════════════════════════════

    /// @notice Unstake and claim all accumulated rewards
    function unstake(uint256 tokenId) external nonReentrant {
        StakeInfo storage info = stakes[tokenId];
        if (info.owner != msg.sender) revert NotStakeOwner(tokenId);

        uint256 reward = _calculateReward(tokenId);

        // Remove from user's staked list
        _removeFromUserList(msg.sender, tokenId);
        delete stakes[tokenId];

        // Return NFT first
        guguNFT.transferFrom(address(this), msg.sender, tokenId);

        // Then distribute rewards
        if (reward > 0) {
            guguToken.transfer(msg.sender, reward);
        }

        emit Unstaked(msg.sender, tokenId, reward);
    }

    /// @notice Batch unstake multiple NFTs
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
            guguToken.transfer(msg.sender, totalReward);
        }
    }

    // ═══════════════════════════════════════════
    //              Claim Rewards
    // ═══════════════════════════════════════════

    /// @notice Claim accumulated rewards for all staked NFTs
    function claimRewards() external nonReentrant {
        uint256[] storage tokenIds = _userStakedTokens[msg.sender];
        uint256 totalReward = 0;

        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            totalReward += _calculateReward(tokenId);
            stakes[tokenId].lastClaimedAt = block.timestamp;
        }

        if (totalReward > 0) {
            guguToken.transfer(msg.sender, totalReward);
        }

        emit RewardsClaimed(msg.sender, totalReward);
    }

    // ═══════════════════════════════════════════
    //                Queries
    // ═══════════════════════════════════════════

    /// @notice View user's total pending rewards
    function pendingRewards(address user) external view returns (uint256) {
        uint256[] storage tokenIds = _userStakedTokens[user];
        uint256 totalReward = 0;

        for (uint256 i = 0; i < tokenIds.length; i++) {
            totalReward += _calculateReward(tokenIds[i]);
        }

        return totalReward;
    }

    /// @notice View all tokenIds staked by a user
    function stakedTokensOf(address user) external view returns (uint256[] memory) {
        return _userStakedTokens[user];
    }

    /// @notice View the number of NFTs staked by a user
    function stakedCountOf(address user) external view returns (uint256) {
        return _userStakedTokens[user].length;
    }

    // ═══════════════════════════════════════════
    //              Owner Management
    // ═══════════════════════════════════════════

    /// @notice Set daily reward for a specific rarity
    function setDailyReward(GUGUNFT.Rarity rarity, uint256 rewardPerDay) external onlyOwner {
        dailyReward[rarity] = rewardPerDay;
        emit DailyRewardUpdated(rarity, rewardPerDay);
    }

    /// @notice Rescue GUGU tokens from the reward pool (emergency / excess recovery)
    /// @param to   Recipient address
    /// @param amount Amount of GUGU to withdraw
    function rescueToken(address to, uint256 amount) external onlyOwner {
        guguToken.transfer(to, amount);
    }

    // ═══════════════════════════════════════════
    //              Internal Methods
    // ═══════════════════════════════════════════

    function _calculateReward(uint256 tokenId) internal view returns (uint256) {
        StakeInfo storage info = stakes[tokenId];
        if (info.owner == address(0)) return 0;

        GUGUNFT.Rarity rarity = guguNFT.getRarity(tokenId);
        uint256 elapsed = block.timestamp - info.lastClaimedAt;
        // dailyReward already includes 1e18 precision, divide by seconds in a day
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

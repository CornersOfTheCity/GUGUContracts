// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {VRFConsumerBaseV2Plus} from
    "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from
    "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {GUGUToken} from "./GUGUToken.sol";
import {GUGUNFT} from "./GUGUNFT.sol";

/**
 * @title MysteryBox
 * @notice 盲盒合约 — 花费 GUGU Token 购买盲盒，使用 Chainlink VRF
 *         产生可验证的随机数来决定 NFT 稀有度。
 *
 *         两步流程:
 *         1) buyBox: 用户扣除 Token(burn) + 发送 VRF 请求
 *         2) fulfillRandomWords: Chainlink 回调 → 铸造 NFT
 */
contract MysteryBox is VRFConsumerBaseV2Plus, ReentrancyGuard {
    GUGUToken public immutable guguToken;
    GUGUNFT public immutable guguNFT;

    /// @notice 盲盒价格 (默认 100 GUGU = 100 * 1e18)
    uint256 public boxPrice = 100 * 1e18;

    /// @notice 概率分布 (基于 10000): [Founder, Pro, Basic]
    ///         默认: Founder 5%, Pro 25%, Basic 70%
    uint256[3] public probabilities = [500, 2500, 7000];

    /// @notice 单次最大购买数量
    uint256 public constant MAX_PER_TX = 5;

    // ── Chainlink VRF 配置 ──
    uint256 public s_subscriptionId;
    bytes32 public s_keyHash;
    uint32 public s_callbackGasLimit = 500_000;
    uint16 public s_requestConfirmations = 3;

    // ── VRF 请求追踪 ──
    struct BoxRequest {
        address buyer;
        uint256 quantity;
        bool fulfilled;
        uint256[] randomWords;
    }

    mapping(uint256 => BoxRequest) public requests;
    uint256[] public requestIds;

    // ── Events ──
    event BoxRequested(address indexed buyer, uint256 indexed requestId, uint256 quantity);
    event BoxOpened(address indexed buyer, uint256 indexed tokenId, GUGUNFT.Rarity rarity);
    event BoxPriceUpdated(uint256 newPrice);
    event ProbabilitiesUpdated(uint256[3] newProbs);

    // ── Errors ──
    error InvalidQuantity();
    error ProbabilitiesMustSum10000();
    error RequestNotFound(uint256 requestId);
    error RequestAlreadyFulfilled(uint256 requestId);

    constructor(
        address _guguToken,
        address _guguNFT,
        address _vrfCoordinator,
        uint256 _subscriptionId,
        bytes32 _keyHash
    ) VRFConsumerBaseV2Plus(_vrfCoordinator) {
        guguToken = GUGUToken(_guguToken);
        guguNFT = GUGUNFT(_guguNFT);
        s_subscriptionId = _subscriptionId;
        s_keyHash = _keyHash;
    }

    // ═══════════════════════════════════════════
    //            步骤 1: 购买盲盒
    // ═══════════════════════════════════════════

    /// @notice 购买盲盒 — 扣除 Token 并发送 VRF 随机数请求
    /// @param quantity 购买数量 (1-5)
    function buyBox(uint256 quantity) external nonReentrant {
        if (quantity == 0 || quantity > MAX_PER_TX) revert InvalidQuantity();

        // Burn Token (用户必须先 approve)
        uint256 totalCost = boxPrice * quantity;
        guguToken.burnFrom(msg.sender, totalCost);

        // 请求 VRF 随机数
        uint256 requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: s_keyHash,
                subId: s_subscriptionId,
                requestConfirmations: s_requestConfirmations,
                callbackGasLimit: s_callbackGasLimit * uint32(quantity),
                numWords: uint32(quantity),
                extraArgs: VRFV2PlusClient._argsToBytes(
                    VRFV2PlusClient.ExtraArgsV1({nativePayment: false})
                )
            })
        );

        requests[requestId] = BoxRequest({
            buyer: msg.sender,
            quantity: quantity,
            fulfilled: false,
            randomWords: new uint256[](0)
        });
        requestIds.push(requestId);

        emit BoxRequested(msg.sender, requestId, quantity);
    }

    // ═══════════════════════════════════════════
    //       步骤 2: Chainlink 回调铸造 NFT
    // ═══════════════════════════════════════════

    /// @dev Chainlink VRF 回调
    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) internal override {
        BoxRequest storage req = requests[requestId];
        if (req.buyer == address(0)) revert RequestNotFound(requestId);
        if (req.fulfilled) revert RequestAlreadyFulfilled(requestId);

        req.fulfilled = true;
        req.randomWords = randomWords;

        // 根据随机数铸造 NFT
        for (uint256 i = 0; i < randomWords.length; i++) {
            GUGUNFT.Rarity rarity = _determineRarity(randomWords[i]);
            uint256 tokenId = guguNFT.mint(req.buyer, rarity);
            emit BoxOpened(req.buyer, tokenId, rarity);
        }
    }

    // ═══════════════════════════════════════════
    //                查询
    // ═══════════════════════════════════════════

    /// @notice 查询 VRF 请求状态
    function getRequestStatus(uint256 requestId)
        external
        view
        returns (bool fulfilled, uint256[] memory randomWords)
    {
        BoxRequest storage req = requests[requestId];
        if (req.buyer == address(0)) revert RequestNotFound(requestId);
        return (req.fulfilled, req.randomWords);
    }

    /// @notice 所有请求 ID
    function getRequestIds() external view returns (uint256[] memory) {
        return requestIds;
    }

    // ═══════════════════════════════════════════
    //              Owner 管理
    // ═══════════════════════════════════════════

    function setBoxPrice(uint256 price) external onlyOwner {
        boxPrice = price;
        emit BoxPriceUpdated(price);
    }

    function setProbabilities(uint256[3] calldata probs) external onlyOwner {
        if (probs[0] + probs[1] + probs[2] != 10000) revert ProbabilitiesMustSum10000();
        probabilities = probs;
        emit ProbabilitiesUpdated(probs);
    }

    function setVRFConfig(
        bytes32 keyHash,
        uint32 callbackGasLimit,
        uint16 requestConfirmations
    ) external onlyOwner {
        s_keyHash = keyHash;
        s_callbackGasLimit = callbackGasLimit;
        s_requestConfirmations = requestConfirmations;
    }

    function setSubscriptionId(uint256 subscriptionId) external onlyOwner {
        s_subscriptionId = subscriptionId;
    }

    // ═══════════════════════════════════════════
    //              内部方法
    // ═══════════════════════════════════════════

    /// @dev 根据随机数决定稀有度
    function _determineRarity(uint256 randomWord) internal view returns (GUGUNFT.Rarity) {
        uint256 roll = randomWord % 10000;

        if (roll < probabilities[0]) {
            return GUGUNFT.Rarity.Founder;
        } else if (roll < probabilities[0] + probabilities[1]) {
            return GUGUNFT.Rarity.Pro;
        } else {
            return GUGUNFT.Rarity.Basic;
        }
    }
}

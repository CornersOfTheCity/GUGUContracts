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
 * @notice Mystery box contract — spend GUGU Tokens to purchase mystery boxes,
 *         using Chainlink VRF to generate verifiable random numbers for NFT rarity.
 *
 *         Dynamic Pricing:
 *           price = min(basePrice × (1 + tier × 0.5), maxPrice)
 *           tier  = totalBoxOpened / 1000
 *
 *         Two-step process:
 *         1) buyBox: User burns tokens + sends VRF request
 *         2) fulfillRandomWords: Chainlink callback → mint NFT
 */
contract MysteryBox is VRFConsumerBaseV2Plus, ReentrancyGuard {
    GUGUToken public immutable guguToken;
    GUGUNFT public immutable guguNFT;

    // ── Dynamic Pricing ──

    /// @notice Base price for mystery box (default 100 GUGU)
    uint256 public basePrice = 100 * 1e18;

    /// @notice Maximum price cap (default 500 GUGU, owner can change)
    uint256 public maxPrice = 500 * 1e18;

    /// @notice Total number of boxes opened (drives tier calculation)
    uint256 public totalBoxOpened;

    /// @notice Probability distribution (based on 10000): [Founder, Pro, Basic]
    ///         Default: Founder 5%, Pro 25%, Basic 70%
    uint256[3] public probabilities = [500, 2500, 7000];

    /// @notice Maximum purchase quantity per transaction
    uint256 public constant MAX_PER_TX = 5;

    // ── Chainlink VRF Configuration ──
    uint256 public s_subscriptionId;
    bytes32 public s_keyHash;
    uint32 public s_callbackGasLimit = 500_000;
    uint16 public s_requestConfirmations = 3;

    // ── VRF Request Tracking ──
    struct BoxRequest {
        address buyer;
        uint256 quantity;
        bool fulfilled;
        uint256[] randomWords;
    }

    mapping(uint256 => BoxRequest) public requests;
    uint256[] public requestIds;

    // ── Events ──
    event BoxRequested(address indexed buyer, uint256 indexed requestId, uint256 quantity, uint256 totalCost);
    event BoxOpened(address indexed buyer, uint256 indexed tokenId, GUGUNFT.Rarity rarity);
    event BasePriceUpdated(uint256 newBasePrice);
    event MaxPriceUpdated(uint256 newMaxPrice);
    event ProbabilitiesUpdated(uint256[3] newProbs);

    // ── Errors ──
    error InvalidQuantity();
    error ProbabilitiesMustSum10000();
    error RequestNotFound(uint256 requestId);
    error RequestAlreadyFulfilled(uint256 requestId);
    error InvalidPrice();

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
    //              Dynamic Pricing
    // ═══════════════════════════════════════════

    /// @notice Calculate the current box price based on total boxes opened
    /// @return price = min(basePrice × (1 + tier × 0.5), maxPrice)
    ///         where tier = totalBoxOpened / 1000
    function currentBoxPrice() public view returns (uint256) {
        uint256 tier = totalBoxOpened / 1000;
        // price = basePrice * (1 + tier * 0.5)
        //       = basePrice * (2 + tier) / 2    (avoid floating point)
        uint256 price = basePrice * (2 + tier) / 2;
        return price < maxPrice ? price : maxPrice;
    }

    // ═══════════════════════════════════════════
    //          Step 1: Purchase Mystery Box
    // ═══════════════════════════════════════════

    /// @notice Purchase mystery box — burn tokens and send VRF random number request
    /// @param quantity Number of boxes to purchase (1-5)
    function buyBox(uint256 quantity) external nonReentrant {
        if (quantity == 0 || quantity > MAX_PER_TX) revert InvalidQuantity();

        // Calculate total cost using dynamic pricing
        uint256 unitPrice = currentBoxPrice();
        uint256 totalCost = unitPrice * quantity;

        // Burn tokens (user must approve beforehand)
        guguToken.burnFrom(msg.sender, totalCost);

        // Request VRF random numbers
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

        emit BoxRequested(msg.sender, requestId, quantity, totalCost);
    }

    // ═══════════════════════════════════════════
    //     Step 2: Chainlink Callback — Mint NFT
    // ═══════════════════════════════════════════

    /// @dev Chainlink VRF callback
    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) internal override {
        BoxRequest storage req = requests[requestId];
        if (req.buyer == address(0)) revert RequestNotFound(requestId);
        if (req.fulfilled) revert RequestAlreadyFulfilled(requestId);

        req.fulfilled = true;
        req.randomWords = randomWords;

        // Increment total box opened counter
        totalBoxOpened += randomWords.length;

        // Mint NFTs based on random numbers
        for (uint256 i = 0; i < randomWords.length; i++) {
            GUGUNFT.Rarity rarity = _determineRarity(randomWords[i]);
            uint256 tokenId = guguNFT.mint(req.buyer, rarity);
            emit BoxOpened(req.buyer, tokenId, rarity);
        }
    }

    // ═══════════════════════════════════════════
    //                Queries
    // ═══════════════════════════════════════════

    /// @notice Query VRF request status
    function getRequestStatus(uint256 requestId)
        external
        view
        returns (bool fulfilled, uint256[] memory randomWords)
    {
        BoxRequest storage req = requests[requestId];
        if (req.buyer == address(0)) revert RequestNotFound(requestId);
        return (req.fulfilled, req.randomWords);
    }

    /// @notice Get all request IDs
    function getRequestIds() external view returns (uint256[] memory) {
        return requestIds;
    }

    // ═══════════════════════════════════════════
    //              Owner Management
    // ═══════════════════════════════════════════

    /// @notice Update the base price for dynamic pricing
    function setBasePrice(uint256 _basePrice) external onlyOwner {
        if (_basePrice == 0) revert InvalidPrice();
        basePrice = _basePrice;
        emit BasePriceUpdated(_basePrice);
    }

    /// @notice Update the maximum price cap
    function setMaxPrice(uint256 _maxPrice) external onlyOwner {
        if (_maxPrice == 0) revert InvalidPrice();
        maxPrice = _maxPrice;
        emit MaxPriceUpdated(_maxPrice);
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
    //              Internal Methods
    // ═══════════════════════════════════════════

    /// @dev Determine NFT rarity based on random number
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

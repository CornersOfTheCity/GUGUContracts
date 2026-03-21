// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {GUGUNFT} from "./GUGUNFT.sol";

/**
 * @title Airdrop
 * @notice Batch airdrop contract — supports batch distribution of ERC-20 tokens and ERC-721 NFTs
 *
 *         Features:
 *         1) airdropToken: Batch airdrop ERC-20 tokens (equal or custom amounts)
 *         2) airdropNFT:   Batch mint NFTs to specified address list (requires GUGUNFT Minter role)
 *
 *         Prerequisites:
 *         - Token airdrop: Owner must first approve sufficient tokens to this contract
 *         - NFT airdrop:   This contract must be added as a minter in the GUGUNFT contract
 */
contract Airdrop is Ownable {
    using SafeERC20 for IERC20;

    GUGUNFT public immutable guguNFT;

    /// @notice Maximum recipients per airdrop to prevent gas limit issues
    uint256 public constant MAX_BATCH_SIZE = 200;

    // ── Events ──
    event TokenAirdropped(address indexed token, uint256 totalRecipients, uint256 totalAmount);
    event NFTAirdropped(uint256 totalRecipients, GUGUNFT.Rarity rarity);

    // ── Errors ──
    error EmptyRecipients();
    error ArrayLengthMismatch();
    error ExceedsMaxBatchSize(uint256 size);

    constructor(address initialOwner, address _guguNFT) Ownable(initialOwner) {
        guguNFT = GUGUNFT(_guguNFT);
    }

    // ═══════════════════════════════════════════
    //         ERC-20 Token Batch Airdrop
    // ═══════════════════════════════════════════

    /// @notice Equal airdrop — distribute the same amount of tokens to each address
    /// @param token      ERC-20 token address
    /// @param recipients List of recipient addresses
    /// @param amountEach Amount each recipient receives (with decimals, e.g. 100 * 1e18)
    function airdropTokenEqual(
        address token,
        address[] calldata recipients,
        uint256 amountEach
    ) external onlyOwner {
        uint256 len = recipients.length;
        if (len == 0) revert EmptyRecipients();
        if (len > MAX_BATCH_SIZE) revert ExceedsMaxBatchSize(len);

        uint256 totalAmount = amountEach * len;

        // Transfer from owner to contract, then distribute
        IERC20(token).safeTransferFrom(msg.sender, address(this), totalAmount);

        for (uint256 i = 0; i < len; i++) {
            IERC20(token).safeTransfer(recipients[i], amountEach);
        }

        emit TokenAirdropped(token, len, totalAmount);
    }

    /// @notice Custom amount airdrop — distribute different amounts to each address
    /// @param token      ERC-20 token address
    /// @param recipients List of recipient addresses
    /// @param amounts    Amount for each recipient (must match recipients length)
    function airdropTokenCustom(
        address token,
        address[] calldata recipients,
        uint256[] calldata amounts
    ) external onlyOwner {
        uint256 len = recipients.length;
        if (len == 0) revert EmptyRecipients();
        if (len != amounts.length) revert ArrayLengthMismatch();
        if (len > MAX_BATCH_SIZE) revert ExceedsMaxBatchSize(len);

        uint256 totalAmount = 0;
        for (uint256 i = 0; i < len; i++) {
            totalAmount += amounts[i];
        }

        // Transfer from owner to contract, then distribute
        IERC20(token).safeTransferFrom(msg.sender, address(this), totalAmount);

        for (uint256 i = 0; i < len; i++) {
            IERC20(token).safeTransfer(recipients[i], amounts[i]);
        }

        emit TokenAirdropped(token, len, totalAmount);
    }

    // ═══════════════════════════════════════════
    //         ERC-721 NFT Batch Airdrop
    // ═══════════════════════════════════════════

    /// @notice Batch mint NFTs to address list (all recipients get the same rarity)
    /// @param recipients List of recipient addresses
    /// @param rarity     NFT rarity tier (0=Founder, 1=Pro, 2=Basic)
    function airdropNFT(
        address[] calldata recipients,
        GUGUNFT.Rarity rarity
    ) external onlyOwner {
        uint256 len = recipients.length;
        if (len == 0) revert EmptyRecipients();
        if (len > MAX_BATCH_SIZE) revert ExceedsMaxBatchSize(len);

        for (uint256 i = 0; i < len; i++) {
            guguNFT.mint(recipients[i], rarity);
        }

        emit NFTAirdropped(len, rarity);
    }

    // ═══════════════════════════════════════════
    //              Emergency Recovery
    // ═══════════════════════════════════════════

    /// @notice Rescue ERC-20 tokens stuck in the contract
    function rescueToken(address token) external onlyOwner {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) {
            IERC20(token).safeTransfer(msg.sender, balance);
        }
    }
}

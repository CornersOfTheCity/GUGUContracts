// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {GUGUNFT} from "./GUGUNFT.sol";

/**
 * @title Airdrop
 * @notice 批量空投合约 — 支持 ERC-20 Token 和 ERC-721 NFT 的批量发放
 *
 *         功能:
 *         1) airdropToken: 批量空投 ERC-20 代币（等额 或 自定义金额）
 *         2) airdropNFT:   批量铸造 NFT 给指定地址列表（需 GUGUNFT Minter 权限）
 *
 *         使用前:
 *         - Token 空投: Owner 需先 approve 足够的 Token 给本合约
 *         - NFT 空投:   需在 GUGUNFT 合约中将本合约 addMinter
 */
contract Airdrop is Ownable {
    using SafeERC20 for IERC20;

    GUGUNFT public immutable guguNFT;

    /// @notice 单次空投最大地址数，防止 gas 超限
    uint256 public constant MAX_BATCH_SIZE = 200;

    // ── Events ──
    event TokenAirdropped(address indexed token, uint256 totalRecipients, uint256 totalAmount);
    event NFTAirdropped(uint256 totalRecipients, GUGUNFT.Rarity rarity);

    // ── Errors ──
    error EmptyRecipients();
    error ArrayLengthMismatch();
    error ExceedsMaxBatchSize(uint256 size);

    constructor(address _guguNFT) Ownable(msg.sender) {
        guguNFT = GUGUNFT(_guguNFT);
    }

    // ═══════════════════════════════════════════
    //         ERC-20 Token 批量空投
    // ═══════════════════════════════════════════

    /// @notice 等额空投 — 给每个地址发放相同数量的 Token
    /// @param token     ERC-20 代币地址
    /// @param recipients 接收地址列表
    /// @param amountEach 每人获得的数量 (含精度, 如 100 * 1e18)
    function airdropTokenEqual(
        address token,
        address[] calldata recipients,
        uint256 amountEach
    ) external onlyOwner {
        uint256 len = recipients.length;
        if (len == 0) revert EmptyRecipients();
        if (len > MAX_BATCH_SIZE) revert ExceedsMaxBatchSize(len);

        uint256 totalAmount = amountEach * len;

        // 从 Owner 转入合约，再分发
        IERC20(token).safeTransferFrom(msg.sender, address(this), totalAmount);

        for (uint256 i = 0; i < len; i++) {
            IERC20(token).safeTransfer(recipients[i], amountEach);
        }

        emit TokenAirdropped(token, len, totalAmount);
    }

    /// @notice 自定义金额空投 — 每个地址发放不同数量
    /// @param token      ERC-20 代币地址
    /// @param recipients 接收地址列表
    /// @param amounts    每人获得的数量列表 (与 recipients 等长)
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

        // 从 Owner 转入合约，再分发
        IERC20(token).safeTransferFrom(msg.sender, address(this), totalAmount);

        for (uint256 i = 0; i < len; i++) {
            IERC20(token).safeTransfer(recipients[i], amounts[i]);
        }

        emit TokenAirdropped(token, len, totalAmount);
    }

    // ═══════════════════════════════════════════
    //         ERC-721 NFT 批量空投
    // ═══════════════════════════════════════════

    /// @notice 批量铸造 NFT 给地址列表（所有人获得相同稀有度）
    /// @param recipients 接收地址列表
    /// @param rarity     NFT 稀有度 (0=Founder, 1=Pro, 2=Basic)
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
    //              紧急恢复
    // ═══════════════════════════════════════════

    /// @notice 取回合约中滞留的 ERC-20 Token
    function rescueToken(address token) external onlyOwner {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) {
            IERC20(token).safeTransfer(msg.sender, balance);
        }
    }
}

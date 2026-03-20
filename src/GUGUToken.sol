// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title GUGUToken
 * @notice ERC-20 代币合约，总量上限 1 亿枚
 *         功能: Owner 铸造、销毁、黑名单
 *
 *         代币分配:
 *         - Uniswap 流动性池: 3,000 万 (30%)
 *         - NFT 质押产出:     4,000 万 (40%)
 *         - 团队持有:         1,500 万 (15%)
 *         - 盲盒运营:         1,000 万 (10%)
 *         - 预留:               500 万 (5%)
 */
contract GUGUToken is ERC20, ERC20Burnable, Ownable {
    /// @notice 代币总量上限: 1 亿枚
    uint256 public constant MAX_SUPPLY = 100_000_000 * 1e18;

    /// @notice 黑名单
    mapping(address => bool) public blacklisted;

    event Blacklisted(address indexed account);
    event Unblacklisted(address indexed account);

    error ExceedsMaxSupply(uint256 attempted, uint256 maxSupply);
    error AccountBlacklisted(address account);

    /**
     * @param initialSupply 初始铸造数量 (含精度, 如 60_000_000 * 1e18)
     */
    constructor(uint256 initialSupply) ERC20("GUGU Token", "GUGU") Ownable(msg.sender) {
        if (initialSupply > MAX_SUPPLY) revert ExceedsMaxSupply(initialSupply, MAX_SUPPLY);
        _mint(msg.sender, initialSupply);
    }

    // ═══════════════════════════════════════════
    //              铸造 (仅 Owner)
    // ═══════════════════════════════════════════

    /// @notice Owner 铸造代币（受 MAX_SUPPLY 上限限制）
    function mint(address to, uint256 amount) external onlyOwner {
        if (totalSupply() + amount > MAX_SUPPLY) {
            revert ExceedsMaxSupply(totalSupply() + amount, MAX_SUPPLY);
        }
        _mint(to, amount);
    }

    // ═══════════════════════════════════════════
    //              黑名单
    // ═══════════════════════════════════════════

    /// @notice 加入黑名单（仅 Owner）
    function addBlacklist(address account) external onlyOwner {
        blacklisted[account] = true;
        emit Blacklisted(account);
    }

    /// @notice 移除黑名单（仅 Owner）
    function removeBlacklist(address account) external onlyOwner {
        blacklisted[account] = false;
        emit Unblacklisted(account);
    }

    // ═══════════════════════════════════════════
    //              转账限制
    // ═══════════════════════════════════════════

    /// @dev 重写 _update 以实现黑名单检查
    function _update(address from, address to, uint256 amount) internal override {
        if (blacklisted[from]) revert AccountBlacklisted(from);
        if (blacklisted[to]) revert AccountBlacklisted(to);
        super._update(from, to, amount);
    }
}

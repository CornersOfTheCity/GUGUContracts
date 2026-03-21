// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title GUGUToken
 * @notice ERC-20 token contract with a hard cap of 100 million tokens
 *         Features: Owner minting, burning, blacklist
 *
 *         Token Allocation:
 *         - Uniswap Liquidity Pool: 30,000,000 (30%)
 *         - NFT Staking Rewards:    40,000,000 (40%)
 *         - Team:                   15,000,000 (15%)
 *         - Mystery Box Operations: 10,000,000 (10%)
 *         - Reserve:                 5,000,000 (5%)
 */
contract GUGUToken is ERC20, ERC20Burnable, Ownable {
    /// @notice Maximum token supply: 100 million
    uint256 public constant MAX_SUPPLY = 100_000_000 * 1e18;

    /// @notice Blacklist
    mapping(address => bool) public blacklisted;

    event Blacklisted(address indexed account);
    event Unblacklisted(address indexed account);

    error ExceedsMaxSupply(uint256 attempted, uint256 maxSupply);
    error AccountBlacklisted(address account);

    /**
     * @param initialOwner Address of the contract owner
     */
    constructor(address initialOwner) ERC20("GUGU Token", "GUGU") Ownable(initialOwner) {}

    // ═══════════════════════════════════════════
    //              Minting (Owner Only)
    // ═══════════════════════════════════════════

    /// @notice Owner mints tokens (capped by MAX_SUPPLY)
    function mint(address to, uint256 amount) external onlyOwner {
        if (totalSupply() + amount > MAX_SUPPLY) {
            revert ExceedsMaxSupply(totalSupply() + amount, MAX_SUPPLY);
        }
        _mint(to, amount);
    }

    // ═══════════════════════════════════════════
    //              Blacklist
    // ═══════════════════════════════════════════

    /// @notice Add to blacklist (Owner only)
    function addBlacklist(address account) external onlyOwner {
        blacklisted[account] = true;
        emit Blacklisted(account);
    }

    /// @notice Remove from blacklist (Owner only)
    function removeBlacklist(address account) external onlyOwner {
        blacklisted[account] = false;
        emit Unblacklisted(account);
    }

    // ═══════════════════════════════════════════
    //              Transfer Restrictions
    // ═══════════════════════════════════════════

    /// @dev Override _update to enforce blacklist checks
    function _update(address from, address to, uint256 amount) internal override {
        if (blacklisted[from]) revert AccountBlacklisted(from);
        if (blacklisted[to]) revert AccountBlacklisted(to);
        super._update(from, to, amount);
    }
}

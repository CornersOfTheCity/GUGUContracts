// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title GUGUToken
 * @notice ERC-20 代币合约，支持 Owner 和授权 Minter 铸币/销毁
 */
contract GUGUToken is ERC20, ERC20Burnable, Ownable {
    /// @notice 授权的 Minter 地址映射
    mapping(address => bool) public minters;

    event MinterAdded(address indexed minter);
    event MinterRemoved(address indexed minter);

    error NotMinter(address caller);

    modifier onlyMinter() {
        if (!minters[msg.sender]) revert NotMinter(msg.sender);
        _;
    }

    /**
     * @param initialSupply 初始铸造数量 (含精度, 如 1_000_000 * 1e18)
     */
    constructor(uint256 initialSupply) ERC20("GUGU Token", "GUGU") Ownable(msg.sender) {
        _mint(msg.sender, initialSupply);
    }

    /// @notice 授权 Minter 铸造代币（仅 Owner）
    function addMinter(address minter) external onlyOwner {
        minters[minter] = true;
        emit MinterAdded(minter);
    }

    /// @notice 移除 Minter 授权（仅 Owner）
    function removeMinter(address minter) external onlyOwner {
        minters[minter] = false;
        emit MinterRemoved(minter);
    }

    /// @notice Minter 铸造代币
    function mint(address to, uint256 amount) external onlyMinter {
        _mint(to, amount);
    }
}

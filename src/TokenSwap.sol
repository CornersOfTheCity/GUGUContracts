// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title TokenSwap
 * @notice Simple token sale contract — buy GUGU with stablecoins (USDT/USDC)
 *         - Users pay stablecoins to purchase GUGU tokens
 *         - Owner can set price, pause sales, and withdraw tokens
 */
contract TokenSwap is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Token being sold (GUGU)
    IERC20 public immutable saleToken;

    /// @notice Payment token (USDT/USDC)
    IERC20 public immutable payToken;

    /// @notice Price per saleToken in payToken (1e18 precision)
    /// @dev e.g. price = 0.1e18 means 1 GUGU = 0.1 USDT
    uint256 public price;

    /// @notice Whether sales are paused
    bool public paused;

    // ── Events ──
    event TokensPurchased(address indexed buyer, uint256 payAmount, uint256 saleAmount);
    event PriceUpdated(uint256 oldPrice, uint256 newPrice);
    event SalePaused(bool paused);
    event TokensWithdrawn(address indexed token, uint256 amount);
    event ETHWithdrawn(uint256 amount);

    // ── Errors ──
    error SaleIsPaused();
    error ZeroAmount();
    error InsufficientSaleBalance(uint256 required, uint256 available);
    error InvalidPrice();

    /**
     * @param _saleToken  Address of the token being sold (GUGU)
     * @param _payToken   Address of the payment stablecoin (USDT/USDC)
     * @param _price      Initial price (1e18 precision)
     * @param _owner      Owner address
     */
    constructor(
        address _saleToken,
        address _payToken,
        uint256 _price,
        address _owner
    ) Ownable(_owner) {
        saleToken = IERC20(_saleToken);
        payToken = IERC20(_payToken);
        price = _price;
    }

    // ═══════════════════════════════════════════
    //                  Buy
    // ═══════════════════════════════════════════

    /// @notice Buy tokens with stablecoins
    /// @param payAmount Amount of stablecoins to spend
    function buy(uint256 payAmount) external nonReentrant {
        if (paused) revert SaleIsPaused();
        if (payAmount == 0) revert ZeroAmount();

        // Calculate output amount
        uint256 saleAmount = (payAmount * 1e18) / price;

        // Check available supply
        uint256 available = saleToken.balanceOf(address(this));
        if (available < saleAmount) revert InsufficientSaleBalance(saleAmount, available);

        // Collect payment
        payToken.safeTransferFrom(msg.sender, address(this), payAmount);

        // Send tokens
        saleToken.safeTransfer(msg.sender, saleAmount);

        emit TokensPurchased(msg.sender, payAmount, saleAmount);
    }

    /// @notice Estimate how many tokens a given payment amount would buy
    function getAmountOut(uint256 payAmount) external view returns (uint256) {
        return (payAmount * 1e18) / price;
    }

    /// @notice Remaining tokens available for sale
    function remainingSupply() external view returns (uint256) {
        return saleToken.balanceOf(address(this));
    }

    // ═══════════════════════════════════════════
    //              Admin Functions
    // ═══════════════════════════════════════════

    /// @notice Set token price
    function setPrice(uint256 _price) external onlyOwner {
        if (_price == 0) revert InvalidPrice();
        uint256 oldPrice = price;
        price = _price;
        emit PriceUpdated(oldPrice, _price);
    }

    /// @notice Pause or resume sales
    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit SalePaused(_paused);
    }

    /// @notice Withdraw any ERC-20 token from the contract
    function withdrawToken(address token, uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        IERC20(token).safeTransfer(msg.sender, amount);
        emit TokensWithdrawn(token, amount);
    }

    /// @notice Withdraw native currency (BNB/ETH)
    function withdrawETH() external onlyOwner {
        uint256 balance = address(this).balance;
        if (balance == 0) revert ZeroAmount();
        (bool success,) = payable(msg.sender).call{value: balance}("");
        require(success, "ETH transfer failed");
        emit ETHWithdrawn(balance);
    }

    receive() external payable {}
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title TokenSwap
 * @notice Multi-token swap contract for GUGU
 *
 *         Features:
 *         - Admin can add multiple payment tokens (USDT, USDC, etc.)
 *         - Each pay token has independent buy and sell (buyback) prices
 *         - Admin can enable/disable buyback globally
 *         - Users buy GUGU with any enabled pay token
 *         - When buyback is enabled, users sell GUGU for any enabled pay token
 *
 *         Price model (1e18 precision):
 *         buyPrice  = how much payToken per 1 GUGU when buying
 *         sellPrice = how much payToken per 1 GUGU when selling back
 *         Typically sellPrice <= buyPrice (spread)
 */
contract TokenSwap is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════
    //                  State
    // ═══════════════════════════════════════════

    /// @notice The token being sold/bought back (GUGU)
    IERC20 public immutable saleToken;

    /// @notice Per-token configuration
    struct PayTokenInfo {
        uint256 buyPrice;   // 1 GUGU = ? payToken (1e18 precision)
        uint256 sellPrice;  // 1 GUGU = ? payToken for buyback (1e18 precision)
        bool enabled;       // whether this pay token is active
    }

    /// @notice Config for each supported pay token
    mapping(address => PayTokenInfo) public payTokens;

    /// @notice Ordered list of all added pay token addresses
    address[] public payTokenList;

    /// @notice Global buyback switch
    bool public buybackEnabled;

    /// @notice Global pause switch
    bool public paused;

    // ── Events ──
    event TokensPurchased(address indexed buyer, address indexed payToken, uint256 payAmount, uint256 saleAmount);
    event TokensSold(address indexed seller, address indexed receiveToken, uint256 guguAmount, uint256 receiveAmount);
    event PayTokenAdded(address indexed token, uint256 buyPrice, uint256 sellPrice);
    event PayTokenRemoved(address indexed token);
    event TokenPricesUpdated(address indexed token, uint256 buyPrice, uint256 sellPrice);
    event BuybackToggled(bool enabled);
    event SalePaused(bool paused);
    event TokensWithdrawn(address indexed token, uint256 amount);
    event ETHWithdrawn(uint256 amount);

    // ── Errors ──
    error SaleIsPaused();
    error ZeroAmount();
    error ZeroAddress();
    error TokenNotEnabled();
    error TokenAlreadyAdded();
    error TokenNotFound();
    error BuybackNotEnabled();
    error InvalidPrice();
    error InvalidDecimals();
    error CannotAddSaleToken();
    error InsufficientSaleBalance(uint256 required, uint256 available);
    error InsufficientBuybackBalance(uint256 required, uint256 available);

    // ── Modifiers ──
    modifier whenNotPaused() {
        if (paused) revert SaleIsPaused();
        _;
    }

    /**
     * @param _saleToken  Address of the GUGU token
     * @param _owner      Admin / owner address
     */
    constructor(address _saleToken, address _owner) Ownable(_owner) {
        saleToken = IERC20(_saleToken);
    }

    // ═══════════════════════════════════════════
    //                  Buy GUGU
    // ═══════════════════════════════════════════

    /// @notice Buy GUGU with an enabled pay token
    /// @param payToken  Address of the payment token
    /// @param payAmount Amount of payToken to spend
    function buy(address payToken, uint256 payAmount) external nonReentrant whenNotPaused {
        if (payAmount == 0) revert ZeroAmount();
        PayTokenInfo storage info = payTokens[payToken];
        if (!info.enabled) revert TokenNotEnabled();

        // saleAmount = payAmount / buyPrice (both 1e18 scaled)
        uint256 saleAmount = (payAmount * 1e18) / info.buyPrice;

        uint256 available = saleToken.balanceOf(address(this));
        if (available < saleAmount) revert InsufficientSaleBalance(saleAmount, available);

        IERC20(payToken).safeTransferFrom(msg.sender, address(this), payAmount);
        saleToken.safeTransfer(msg.sender, saleAmount);

        emit TokensPurchased(msg.sender, payToken, payAmount, saleAmount);
    }

    /// @notice Estimate GUGU output for a buy
    function getBuyAmountOut(address payToken, uint256 payAmount) external view returns (uint256) {
        PayTokenInfo storage info = payTokens[payToken];
        if (!info.enabled || info.buyPrice == 0) return 0;
        return (payAmount * 1e18) / info.buyPrice;
    }

    // ═══════════════════════════════════════════
    //              Sell GUGU (Buyback)
    // ═══════════════════════════════════════════

    /// @notice Sell GUGU for an enabled pay token (buyback)
    /// @param receiveToken Address of the token to receive
    /// @param guguAmount   Amount of GUGU to sell
    function sell(address receiveToken, uint256 guguAmount) external nonReentrant whenNotPaused {
        if (!buybackEnabled) revert BuybackNotEnabled();
        if (guguAmount == 0) revert ZeroAmount();
        PayTokenInfo storage info = payTokens[receiveToken];
        if (!info.enabled) revert TokenNotEnabled();
        if (info.sellPrice == 0) revert InvalidPrice();

        // receiveAmount = guguAmount * sellPrice / 1e18
        uint256 receiveAmount = (guguAmount * info.sellPrice) / 1e18;

        uint256 available = IERC20(receiveToken).balanceOf(address(this));
        if (available < receiveAmount) revert InsufficientBuybackBalance(receiveAmount, available);

        saleToken.safeTransferFrom(msg.sender, address(this), guguAmount);
        IERC20(receiveToken).safeTransfer(msg.sender, receiveAmount);

        emit TokensSold(msg.sender, receiveToken, guguAmount, receiveAmount);
    }

    /// @notice Estimate pay token output for a sell (buyback)
    function getSellAmountOut(address receiveToken, uint256 guguAmount) external view returns (uint256) {
        PayTokenInfo storage info = payTokens[receiveToken];
        if (!info.enabled || info.sellPrice == 0) return 0;
        return (guguAmount * info.sellPrice) / 1e18;
    }

    // ═══════════════════════════════════════════
    //                  Queries
    // ═══════════════════════════════════════════

    /// @notice Remaining GUGU available for sale
    function remainingSupply() external view returns (uint256) {
        return saleToken.balanceOf(address(this));
    }

    /// @notice Get all registered pay token addresses
    function getPayTokenList() external view returns (address[] memory) {
        return payTokenList;
    }

    /// @notice Get config for a specific pay token
    function getPayTokenInfo(address token) external view returns (uint256 buyPrice, uint256 sellPrice, bool enabled) {
        PayTokenInfo storage info = payTokens[token];
        return (info.buyPrice, info.sellPrice, info.enabled);
    }

    /// @notice Number of registered pay tokens
    function payTokenCount() external view returns (uint256) {
        return payTokenList.length;
    }

    // ═══════════════════════════════════════════
    //              Admin Functions
    // ═══════════════════════════════════════════

    /// @notice Add a new pay token
    function addPayToken(address token, uint256 buyPrice, uint256 sellPrice) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (token == address(saleToken)) revert CannotAddSaleToken();
        if (buyPrice == 0) revert InvalidPrice();
        if (IERC20Metadata(token).decimals() != 18) revert InvalidDecimals();
        if (payTokens[token].buyPrice != 0) revert TokenAlreadyAdded();

        payTokens[token] = PayTokenInfo({
            buyPrice: buyPrice,
            sellPrice: sellPrice,
            enabled: true
        });
        payTokenList.push(token);

        emit PayTokenAdded(token, buyPrice, sellPrice);
    }

    /// @notice Remove a pay token (disables and removes from list)
    function removePayToken(address token) external onlyOwner {
        if (payTokens[token].buyPrice == 0) revert TokenNotFound();

        delete payTokens[token];

        // Remove from array (swap & pop)
        for (uint256 i = 0; i < payTokenList.length; i++) {
            if (payTokenList[i] == token) {
                payTokenList[i] = payTokenList[payTokenList.length - 1];
                payTokenList.pop();
                break;
            }
        }

        emit PayTokenRemoved(token);
    }

    /// @notice Update prices for a pay token
    function setTokenPrices(address token, uint256 buyPrice, uint256 sellPrice) external onlyOwner {
        if (payTokens[token].buyPrice == 0) revert TokenNotFound();
        if (buyPrice == 0) revert InvalidPrice();

        payTokens[token].buyPrice = buyPrice;
        payTokens[token].sellPrice = sellPrice;

        emit TokenPricesUpdated(token, buyPrice, sellPrice);
    }

    /// @notice Enable or disable a specific pay token
    function setTokenEnabled(address token, bool enabled) external onlyOwner {
        if (payTokens[token].buyPrice == 0) revert TokenNotFound();
        payTokens[token].enabled = enabled;
    }

    /// @notice Toggle global buyback
    function setBuybackEnabled(bool _enabled) external onlyOwner {
        buybackEnabled = _enabled;
        emit BuybackToggled(_enabled);
    }

    /// @notice Pause or resume all operations
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

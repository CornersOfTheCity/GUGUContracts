// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title TokenSwap
 * @notice Fixed-rate swap between ERC-20 tokens
 *         - Owner adds trading pairs and sets exchange rates
 *         - Users can swap in both directions
 *         - Configurable fee (default 0.3%)
 *         - Contract holds the liquidity pool
 */
contract TokenSwap is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Fee precision (10000 = 100%)
    uint256 public constant FEE_DENOMINATOR = 10000;

    /// @notice Fee rate (default 30 = 0.3%)
    uint256 public feeRate = 30;

    /// @notice Fee recipient address
    address public feeRecipient;

    /// @notice Trading pair information
    struct SwapPair {
        address tokenA;
        address tokenB;
        uint256 rateAtoB; // tokenA → tokenB rate (1e18 precision, i.e. 1 tokenA = rateAtoB/1e18 tokenB)
        uint256 rateBtoA; // tokenB → tokenA rate (1e18 precision)
        bool active;
    }

    /// @notice All trading pairs
    SwapPair[] public pairs;

    // ── Events ──
    event PairAdded(
        uint256 indexed pairId, address tokenA, address tokenB, uint256 rateAtoB, uint256 rateBtoA
    );
    event PairUpdated(uint256 indexed pairId, uint256 rateAtoB, uint256 rateBtoA);
    event PairActiveChanged(uint256 indexed pairId, bool active);
    event Swapped(
        address indexed user,
        uint256 indexed pairId,
        address fromToken,
        uint256 amountIn,
        uint256 amountOut,
        uint256 fee
    );
    event LiquidityAdded(uint256 indexed pairId, address token, uint256 amount);
    event LiquidityRemoved(uint256 indexed pairId, address token, uint256 amount);
    event FeeRateUpdated(uint256 newFeeRate);
    event FeeRecipientUpdated(address newRecipient);

    // ── Errors ──
    error PairNotActive(uint256 pairId);
    error InvalidPairId(uint256 pairId);
    error InvalidToken(address token);
    error InsufficientLiquidity(uint256 required, uint256 available);
    error FeeRateTooHigh(uint256 feeRate);
    error ZeroAmount();

    constructor(address initialOwner) Ownable(initialOwner) {
        feeRecipient = initialOwner;
    }

    // ═══════════════════════════════════════════
    //        Trading Pair Management (Owner)
    // ═══════════════════════════════════════════

    /// @notice Add a trading pair
    function addPair(
        address tokenA,
        address tokenB,
        uint256 rateAtoB,
        uint256 rateBtoA
    ) external onlyOwner returns (uint256 pairId) {
        pairId = pairs.length;
        pairs.push(
            SwapPair({
                tokenA: tokenA,
                tokenB: tokenB,
                rateAtoB: rateAtoB,
                rateBtoA: rateBtoA,
                active: true
            })
        );
        emit PairAdded(pairId, tokenA, tokenB, rateAtoB, rateBtoA);
    }

    /// @notice Update trading pair rates
    function updatePairRates(uint256 pairId, uint256 rateAtoB, uint256 rateBtoA) external onlyOwner {
        if (pairId >= pairs.length) revert InvalidPairId(pairId);
        pairs[pairId].rateAtoB = rateAtoB;
        pairs[pairId].rateBtoA = rateBtoA;
        emit PairUpdated(pairId, rateAtoB, rateBtoA);
    }

    /// @notice Pause/resume a trading pair
    function setPairActive(uint256 pairId, bool active) external onlyOwner {
        if (pairId >= pairs.length) revert InvalidPairId(pairId);
        pairs[pairId].active = active;
        emit PairActiveChanged(pairId, active);
    }

    // ═══════════════════════════════════════════
    //        Liquidity Management (Owner)
    // ═══════════════════════════════════════════

    /// @notice Deposit liquidity
    function addLiquidity(uint256 pairId, address token, uint256 amount) external onlyOwner {
        if (pairId >= pairs.length) revert InvalidPairId(pairId);
        SwapPair storage pair = pairs[pairId];
        if (token != pair.tokenA && token != pair.tokenB) revert InvalidToken(token);

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit LiquidityAdded(pairId, token, amount);
    }

    /// @notice Withdraw liquidity
    function removeLiquidity(uint256 pairId, address token, uint256 amount) external onlyOwner {
        if (pairId >= pairs.length) revert InvalidPairId(pairId);
        SwapPair storage pair = pairs[pairId];
        if (token != pair.tokenA && token != pair.tokenB) revert InvalidToken(token);

        IERC20(token).safeTransfer(msg.sender, amount);
        emit LiquidityRemoved(pairId, token, amount);
    }

    // ═══════════════════════════════════════════
    //                  Swap
    // ═══════════════════════════════════════════

    /// @notice Swap tokens
    /// @param pairId    Trading pair ID
    /// @param fromToken Input token address
    /// @param amount    Input amount
    function swap(uint256 pairId, address fromToken, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (pairId >= pairs.length) revert InvalidPairId(pairId);

        SwapPair storage pair = pairs[pairId];
        if (!pair.active) revert PairNotActive(pairId);

        address toToken;
        uint256 rate;

        if (fromToken == pair.tokenA) {
            toToken = pair.tokenB;
            rate = pair.rateAtoB;
        } else if (fromToken == pair.tokenB) {
            toToken = pair.tokenA;
            rate = pair.rateBtoA;
        } else {
            revert InvalidToken(fromToken);
        }

        // Calculate output amount
        uint256 amountOut = (amount * rate) / 1e18;

        // Calculate fee
        uint256 fee = (amountOut * feeRate) / FEE_DENOMINATOR;
        uint256 amountOutAfterFee = amountOut - fee;

        // Check liquidity
        uint256 available = IERC20(toToken).balanceOf(address(this));
        if (available < amountOut) revert InsufficientLiquidity(amountOut, available);

        // Execute swap
        IERC20(fromToken).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(toToken).safeTransfer(msg.sender, amountOutAfterFee);

        // Transfer fee
        if (fee > 0 && feeRecipient != address(this)) {
            IERC20(toToken).safeTransfer(feeRecipient, fee);
        }

        emit Swapped(msg.sender, pairId, fromToken, amount, amountOutAfterFee, fee);
    }

    // ═══════════════════════════════════════════
    //              Fee Management
    // ═══════════════════════════════════════════

    function setFeeRate(uint256 _feeRate) external onlyOwner {
        if (_feeRate > 1000) revert FeeRateTooHigh(_feeRate); // Max 10%
        feeRate = _feeRate;
        emit FeeRateUpdated(_feeRate);
    }

    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        feeRecipient = _feeRecipient;
        emit FeeRecipientUpdated(_feeRecipient);
    }

    // ═══════════════════════════════════════════
    //                Queries
    // ═══════════════════════════════════════════

    /// @notice Estimate swap output amount (after fee deduction)
    function getAmountOut(uint256 pairId, address fromToken, uint256 amountIn)
        external
        view
        returns (uint256 amountOut, uint256 fee)
    {
        if (pairId >= pairs.length) revert InvalidPairId(pairId);
        SwapPair storage pair = pairs[pairId];

        uint256 rate;
        if (fromToken == pair.tokenA) {
            rate = pair.rateAtoB;
        } else if (fromToken == pair.tokenB) {
            rate = pair.rateBtoA;
        } else {
            revert InvalidToken(fromToken);
        }

        uint256 rawOut = (amountIn * rate) / 1e18;
        fee = (rawOut * feeRate) / FEE_DENOMINATOR;
        amountOut = rawOut - fee;
    }

    /// @notice Total number of trading pairs
    function pairCount() external view returns (uint256) {
        return pairs.length;
    }

    /// @notice Get trading pair details
    function getPair(uint256 pairId) external view returns (SwapPair memory) {
        if (pairId >= pairs.length) revert InvalidPairId(pairId);
        return pairs[pairId];
    }
}

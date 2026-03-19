// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title TokenSwap
 * @notice 按固定比例在 ERC-20 代币之间进行兑换
 *         - Owner 添加交易对并设定兑换比例
 *         - 用户双向兑换
 *         - 收取可配置手续费 (默认 0.3%)
 *         - 合约持有流动性池
 */
contract TokenSwap is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice 手续费精度 (10000 = 100%)
    uint256 public constant FEE_DENOMINATOR = 10000;

    /// @notice 手续费率 (默认 30 = 0.3%)
    uint256 public feeRate = 30;

    /// @notice 手续费接收地址
    address public feeRecipient;

    /// @notice 交易对信息
    struct SwapPair {
        address tokenA;
        address tokenB;
        uint256 rateAtoB; // tokenA → tokenB 比例 (精度 1e18, 即 1 tokenA = rateAtoB/1e18 tokenB)
        uint256 rateBtoA; // tokenB → tokenA 比例 (精度 1e18)
        bool active;
    }

    /// @notice 所有交易对
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

    constructor() Ownable(msg.sender) {
        feeRecipient = msg.sender;
    }

    // ═══════════════════════════════════════════
    //            交易对管理 (Owner)
    // ═══════════════════════════════════════════

    /// @notice 添加交易对
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

    /// @notice 更新交易对比例
    function updatePairRates(uint256 pairId, uint256 rateAtoB, uint256 rateBtoA) external onlyOwner {
        if (pairId >= pairs.length) revert InvalidPairId(pairId);
        pairs[pairId].rateAtoB = rateAtoB;
        pairs[pairId].rateBtoA = rateBtoA;
        emit PairUpdated(pairId, rateAtoB, rateBtoA);
    }

    /// @notice 暂停/恢复交易对
    function setPairActive(uint256 pairId, bool active) external onlyOwner {
        if (pairId >= pairs.length) revert InvalidPairId(pairId);
        pairs[pairId].active = active;
        emit PairActiveChanged(pairId, active);
    }

    // ═══════════════════════════════════════════
    //              流动性管理 (Owner)
    // ═══════════════════════════════════════════

    /// @notice 存入流动性
    function addLiquidity(uint256 pairId, address token, uint256 amount) external onlyOwner {
        if (pairId >= pairs.length) revert InvalidPairId(pairId);
        SwapPair storage pair = pairs[pairId];
        if (token != pair.tokenA && token != pair.tokenB) revert InvalidToken(token);

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit LiquidityAdded(pairId, token, amount);
    }

    /// @notice 提取流动性
    function removeLiquidity(uint256 pairId, address token, uint256 amount) external onlyOwner {
        if (pairId >= pairs.length) revert InvalidPairId(pairId);
        SwapPair storage pair = pairs[pairId];
        if (token != pair.tokenA && token != pair.tokenB) revert InvalidToken(token);

        IERC20(token).safeTransfer(msg.sender, amount);
        emit LiquidityRemoved(pairId, token, amount);
    }

    // ═══════════════════════════════════════════
    //                 兑换
    // ═══════════════════════════════════════════

    /// @notice 兑换代币
    /// @param pairId    交易对 ID
    /// @param fromToken 输入代币地址
    /// @param amount    输入数量
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

        // 计算输出数量
        uint256 amountOut = (amount * rate) / 1e18;

        // 计算手续费
        uint256 fee = (amountOut * feeRate) / FEE_DENOMINATOR;
        uint256 amountOutAfterFee = amountOut - fee;

        // 检查流动性
        uint256 available = IERC20(toToken).balanceOf(address(this));
        if (available < amountOut) revert InsufficientLiquidity(amountOut, available);

        // 执行交换
        IERC20(fromToken).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(toToken).safeTransfer(msg.sender, amountOutAfterFee);

        // 发送手续费
        if (fee > 0 && feeRecipient != address(this)) {
            IERC20(toToken).safeTransfer(feeRecipient, fee);
        }

        emit Swapped(msg.sender, pairId, fromToken, amount, amountOutAfterFee, fee);
    }

    // ═══════════════════════════════════════════
    //              手续费管理
    // ═══════════════════════════════════════════

    function setFeeRate(uint256 _feeRate) external onlyOwner {
        if (_feeRate > 1000) revert FeeRateTooHigh(_feeRate); // 最高 10%
        feeRate = _feeRate;
        emit FeeRateUpdated(_feeRate);
    }

    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        feeRecipient = _feeRecipient;
        emit FeeRecipientUpdated(_feeRecipient);
    }

    // ═══════════════════════════════════════════
    //                查询
    // ═══════════════════════════════════════════

    /// @notice 预计兑换输出量 (扣除手续费后)
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

    /// @notice 交易对总数
    function pairCount() external view returns (uint256) {
        return pairs.length;
    }

    /// @notice 查询交易对详情
    function getPair(uint256 pairId) external view returns (SwapPair memory) {
        if (pairId >= pairs.length) revert InvalidPairId(pairId);
        return pairs[pairId];
    }
}

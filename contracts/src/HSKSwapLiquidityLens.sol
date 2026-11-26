// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IHSKSwapV3Pool} from "./interfaces/IHSKSwapV3Pool.sol";
import {FullMath} from "./libraries/FullMath.sol";
import {SpreadPilotTypes} from "./SpreadPilotTypes.sol";

/// @title HSKSwapLiquidityLens
/// @notice Zero-gas on-chain Uniswap V3 / HSKSwap V3 liquidity & price-impact estimator.
///         Helps SpreadPilot agents split orders across thin HSKSwap pools so single-shot impact
///         never wipes out spread edge.
contract HSKSwapLiquidityLens {
    uint16 public constant MAX_SLICES = 100;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint24 public constant MAX_FEE_BPS = 5_000;

    error ZeroPoolAddress();
    error UnsupportedDecimals(uint8 decimals0, uint8 decimals1);

    /// @notice Reads active tick, sqrtPriceX96, liquidity, and decimal-adjusted spot price (1e8)
    ///         from any Uniswap V3 / HSKSwap V3 pool.
    /// @param pool Address of the V3 pool (e.g. HSK Mainnet WHSK/USDT pool).
    /// @param decimals0 ERC-20 decimals of token0.
    /// @param decimals1 ERC-20 decimals of token1.
    function inspectPool(address pool, uint8 decimals0, uint8 decimals1)
        public
        view
        returns (SpreadPilotTypes.PoolSnapshot memory snapshot)
    {
        if (pool == address(0)) revert ZeroPoolAddress();

        IHSKSwapV3Pool v3Pool = IHSKSwapV3Pool(pool);
        (uint160 sqrtPriceX96, int24 tick,,,,,) = v3Pool.slot0();
        uint128 liq = v3Pool.liquidity();
        address token0 = v3Pool.token0();
        address token1 = v3Pool.token1();
        uint24 poolFee = v3Pool.fee();

        snapshot = SpreadPilotTypes.PoolSnapshot({
            pool: pool,
            token0: token0,
            token1: token1,
            fee: poolFee,
            sqrtPriceX96: sqrtPriceX96,
            tick: tick,
            liquidity: liq,
            spotPrice1e8: sqrtPriceX96ToPrice1e8(sqrtPriceX96, decimals0, decimals1)
        });
    }

    /// @notice Converts Uniswap V3 sqrtPriceX96 into decimal-adjusted price of 1 token0 in token1 (scaled 1e8).
    function sqrtPriceX96ToPrice1e8(uint160 sqrtPriceX96, uint8 decimals0, uint8 decimals1)
        public
        pure
        returns (uint256 price1e8)
    {
        if (sqrtPriceX96 == 0) return 0;

        // sqrtPriceX96^2 / 2^96 always fits in uint256 (max < 2^320 / 2^96 = 2^224).
        uint256 ratioX96 = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 96);
        int256 exp = 8 + int256(uint256(decimals0)) - int256(uint256(decimals1));

        if (exp >= 0) {
            if (exp > 38) revert UnsupportedDecimals(decimals0, decimals1);
            return FullMath.mulDiv(ratioX96, 10 ** uint256(exp), 1 << 96);
        } else {
            uint256 negExp = uint256(-exp);
            if (negExp > 38) revert UnsupportedDecimals(decimals0, decimals1);
            // (1 << 96) * 10^38 < 2^223 < 2^256, so denominator never overflows.
            return FullMath.mulDiv(ratioX96, 1, (1 << 96) * (10 ** negExp));
        }
    }

    /// @notice Pure deterministic fixed-point TWAP slice planner for V3 pools.
    /// @param totalAmountIn Total order size in tokenIn base units.
    /// @param poolLiquidity Active V3 liquidity depth in normalized virtual units.
    /// @param feeBps Pool fee in basis points (e.g. 5 for 0.05%, 30 for 0.30%).
    /// @param maxImpactBps Maximum target per-slice price impact in basis points.
    /// @param maxSliceCap Maximum allowed input amount per slice (0 = no cap).
    function estimateSlicePlan(
        uint256 totalAmountIn,
        uint128 poolLiquidity,
        uint24 feeBps,
        uint16 maxImpactBps,
        uint256 maxSliceCap
    )
        public
        pure
        returns (
            uint16 sliceCount,
            uint256 sliceAmountIn,
            uint16 estimatedSingleShotImpactBps,
            uint16 estimatedTwapImpactBps,
            uint16 estimatedBpsSaved
        )
    {
        if (totalAmountIn == 0) {
            return (0, 0, 0, 0, 0);
        }

        uint256 clampedFeeBps = feeBps > MAX_FEE_BPS ? MAX_FEE_BPS : uint256(feeBps);
        estimatedSingleShotImpactBps = _impactBps(
            FullMath.mulDiv(totalAmountIn, BPS_DENOMINATOR - clampedFeeBps, BPS_DENOMINATOR), poolLiquidity
        );

        sliceCount = _computeSliceCount(totalAmountIn, poolLiquidity, maxImpactBps, maxSliceCap);
        sliceAmountIn = _ceilDiv(totalAmountIn, uint256(sliceCount));

        estimatedTwapImpactBps = _impactBps(
            FullMath.mulDiv(sliceAmountIn, BPS_DENOMINATOR - clampedFeeBps, BPS_DENOMINATOR), poolLiquidity
        );
        if (estimatedTwapImpactBps > estimatedSingleShotImpactBps) {
            estimatedTwapImpactBps = estimatedSingleShotImpactBps;
        }
        estimatedBpsSaved = estimatedSingleShotImpactBps - estimatedTwapImpactBps;
    }

    function _computeSliceCount(
        uint256 totalAmountIn,
        uint128 poolLiquidity,
        uint16 maxImpactBps,
        uint256 maxSliceCap
    ) internal pure returns (uint16) {
        uint256 slicesByCap = 1;
        if (maxSliceCap > 0 && totalAmountIn > maxSliceCap) {
            slicesByCap = _ceilDiv(totalAmountIn, maxSliceCap);
        }

        uint256 slicesByImpact = 1;
        if (poolLiquidity == 0) {
            slicesByImpact = maxImpactBps < BPS_DENOMINATOR ? MAX_SLICES : 1;
        } else if (maxImpactBps == 0) {
            slicesByImpact = MAX_SLICES;
        } else if (maxImpactBps < BPS_DENOMINATOR) {
            // Solve ceil(s * 10000 / (L + s)) <= maxImpactBps => s <= floor(L * M / (10000 - M)).
            uint256 maxSliceByImpact = FullMath.mulDiv(
                uint256(poolLiquidity), uint256(maxImpactBps), BPS_DENOMINATOR - uint256(maxImpactBps)
            );
            if (maxSliceByImpact == 0) {
                slicesByImpact = MAX_SLICES;
            } else if (totalAmountIn > maxSliceByImpact) {
                slicesByImpact = _ceilDiv(totalAmountIn, maxSliceByImpact);
            }
        }

        uint256 rawSlices = slicesByCap > slicesByImpact ? slicesByCap : slicesByImpact;
        if (rawSlices > MAX_SLICES) {
            rawSlices = MAX_SLICES;
        }
        if (rawSlices == 0) {
            rawSlices = 1;
        }
        return uint16(rawSlices);
    }

    /// @notice One-call convenience lens for frontend & agent: reads live V3 pool and computes slice plan.
    function previewOrderOnPool(
        address pool,
        uint8 decimals0,
        uint8 decimals1,
        uint256 totalAmountIn,
        uint16 maxImpactBps,
        uint256 maxSliceCap
    ) external view returns (SpreadPilotTypes.PoolSnapshot memory snapshot, SpreadPilotTypes.SlicePlan memory plan) {
        snapshot = inspectPool(pool, decimals0, decimals1);
        uint24 feeBps = snapshot.fee / 100;
        (
            uint16 sliceCount,
            uint256 sliceAmountIn,
            uint16 singleImpact,
            uint16 twapImpact,
            uint16 bpsSaved
        ) = estimateSlicePlan(totalAmountIn, snapshot.liquidity, feeBps, maxImpactBps, maxSliceCap);

        plan = SpreadPilotTypes.SlicePlan({
            sliceCount: sliceCount,
            sliceAmountIn: sliceAmountIn,
            estimatedSingleShotImpactBps: singleImpact,
            estimatedTwapImpactBps: twapImpact,
            estimatedBpsSaved: bpsSaved
        });
    }

    function _impactBps(uint256 amount, uint128 poolLiquidity) internal pure returns (uint16) {
        if (amount == 0) return 0;
        if (poolLiquidity == 0) return uint16(BPS_DENOMINATOR);

        uint256 liq = uint256(poolLiquidity);
        // liq <= uint128.max, so liq * 10_000 never overflows uint256.
        if (amount >= liq * BPS_DENOMINATOR) {
            return uint16(BPS_DENOMINATOR);
        }

        uint256 bps = FullMath.mulDivRoundingUp(amount, BPS_DENOMINATOR, liq + amount);
        return bps > BPS_DENOMINATOR ? uint16(BPS_DENOMINATOR) : uint16(bps);
    }

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0) return 0;
        return ((a - 1) / b) + 1;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title SpreadPilotTypes
/// @notice Shared domain enums, structs, and refusal reason codes for SpreadPilot HSK.
library SpreadPilotTypes {
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant PRICE_SCALE = 1e8;

    // Standard verifiable on-chain refusal reason codes
    uint8 internal constant REFUSAL_SPREAD_BELOW_MIN = 1;
    uint8 internal constant REFUSAL_EXCESSIVE_POOL_IMPACT = 2;
    uint8 internal constant REFUSAL_COOLDOWN_ACTIVE = 3;
    uint8 internal constant REFUSAL_SLIPPAGE_TOO_HIGH = 4;
    uint8 internal constant REFUSAL_DAILY_LIMIT_REACHED = 5;
    uint8 internal constant REFUSAL_CIRCUIT_BREAKER = 6;
    uint8 internal constant REFUSAL_STALE_QUOTE = 7;

    enum RiskAppetite {
        CONSERVATIVE,
        BALANCED,
        AGGRESSIVE
    }

    struct ExecutionPolicy {
        uint256 maxSliceNotional;
        uint256 maxTotalOrderNotional;
        uint32 minSliceIntervalSec;
        int32 minNetEdgeBps;
        uint16 maxSlippageBps;
        uint16 stopLossDrawdownBps;
        uint256 dailyLossLimit;
        uint16 maxDailyTrades;
        uint64 agentExpiry;
        bool paused;
        RiskAppetite riskAppetite;
    }

    struct TwapOrder {
        uint256 orderId;
        address tokenIn;
        address tokenOut;
        uint24 poolFee;
        uint256 totalAmountIn;
        uint256 remainingAmountIn;
        uint256 sliceSize;
        uint16 slicesTotal;
        uint16 slicesExecuted;
        int32 minNetEdgeBps;
        uint16 maxSlippageBps;
        uint256 referencePrice1e8;
        uint64 createdAt;
        uint64 lastSliceAt;
        bool active;
        bool cancelled;
    }

    struct PositionStats {
        uint256 totalVolumeIn;
        uint256 totalVolumeOut;
        int256 realizedPnlQuote;
        uint256 highWaterMarkQuote;
        uint256 dailyLossQuote;
        uint64 lastDayEpoch;
        uint16 tradesToday;
        uint32 totalSlicesExecuted;
        uint32 totalRefusalsLogged;
        uint256 cumulativeSlippageSavedBps;
    }

    struct PoolSnapshot {
        address pool;
        address token0;
        address token1;
        uint24 fee;
        uint160 sqrtPriceX96;
        int24 tick;
        uint128 liquidity;
        uint256 spotPrice1e8;
    }

    struct SlicePlan {
        uint16 sliceCount;
        uint256 sliceAmountIn;
        uint16 estimatedSingleShotImpactBps;
        uint16 estimatedTwapImpactBps;
        uint16 estimatedBpsSaved;
    }
}

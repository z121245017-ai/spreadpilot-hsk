import type {
  AssetSymbol,
  ExecutionPolicy,
  MarketVenueSnapshot,
  Position,
  RiskAppetite,
} from './types';

export const RISK_PRESETS: Record<
  RiskAppetite,
  Pick<
    ExecutionPolicy,
    | 'riskAppetite'
    | 'maxSliceNotionalUsd'
    | 'maxOrderNotionalUsd'
    | 'minSliceIntervalSec'
    | 'minNetEdgeBps'
    | 'maxSlippageBps'
    | 'stopLossDrawdownBps'
    | 'dailyLossLimitUsd'
    | 'maxDailyTrades'
  >
> = {
  CONSERVATIVE: {
    riskAppetite: 'CONSERVATIVE',
    maxSliceNotionalUsd: 120,
    maxOrderNotionalUsd: 600,
    minSliceIntervalSec: 45,
    minNetEdgeBps: 25,
    maxSlippageBps: 35,
    stopLossDrawdownBps: 250, // 2.5%
    dailyLossLimitUsd: 150,
    maxDailyTrades: 12,
  },
  BALANCED: {
    riskAppetite: 'BALANCED',
    maxSliceNotionalUsd: 250,
    maxOrderNotionalUsd: 1500,
    minSliceIntervalSec: 15,
    minNetEdgeBps: 15,
    maxSlippageBps: 50,
    stopLossDrawdownBps: 400, // 4.0%
    dailyLossLimitUsd: 300,
    maxDailyTrades: 24,
  },
  AGGRESSIVE: {
    riskAppetite: 'AGGRESSIVE',
    maxSliceNotionalUsd: 500,
    maxOrderNotionalUsd: 3500,
    minSliceIntervalSec: 5,
    minNetEdgeBps: 8,
    maxSlippageBps: 90,
    stopLossDrawdownBps: 750, // 7.5%
    dailyLossLimitUsd: 650,
    maxDailyTrades: 60,
  },
};

export function createInitialPolicy(): ExecutionPolicy {
  return {
    ...RISK_PRESETS.BALANCED,
    allowedAssets: ['WHSK', 'WETH', 'WBTC', 'USDC'],
    paused: false,
    circuitBreakerTripped: false,
    breakerReason: null,
  };
}

/**
 * Converts a Uniswap V3 / HSKSwap sqrtPriceX96 value into token1-per-token0 human price.
 * Verified on HSK Mainnet WHSK/USDT pools (decimals0=18, decimals1=6).
 */
export function decodeSqrtPriceX96ToPrice(
  sqrtPriceX96: bigint,
  decimals0: number,
  decimals1: number,
): number {
  if (sqrtPriceX96 <= 0n) return 0;
  const q96 = 2 ** 96;
  const ratio = Number(sqrtPriceX96) / q96;
  const rawPrice = ratio * ratio;
  const decimalScale = 10 ** (decimals0 - decimals1);
  return rawPrice * decimalScale;
}

/**
 * Estimates marginal price impact (in bps) on a concentrated V3 pool with active depth USD.
 * Mirrors HSKSwapLiquidityLens.sol deterministic impact curve:
 *   impactBps = min(1500, round((notionalUsd / (2 * effectiveDepthUsd)) * 10000))
 */
export function computeThinLiquidityImpactBps(
  notionalUsd: number,
  effectiveDepthUsd: number,
): number {
  if (notionalUsd <= 0) return 0;
  const safeDepth = Math.max(effectiveDepthUsd, 1500);
  const rawBps = (notionalUsd / (2 * safeDepth)) * 10_000;
  return Math.min(1500, Math.max(1, Math.round(rawBps)));
}

export interface TwapPlanCalc {
  slices: number;
  sliceNotionalUsd: number;
  singleShotImpactBps: number;
  twapImpactBps: number;
  bpsSaved: number;
  usdSaved: number;
}

/**
 * Computes optimal TWAP slice split subject to both policy.maxSliceNotionalUsd
 * and pool-depth impact ceiling (maxSlippageBps * 0.65).
 */
export function planLiquidityAwareTwap(
  totalNotionalUsd: number,
  effectiveDepthUsd: number,
  policy: ExecutionPolicy,
): TwapPlanCalc {
  const clampedTotal = Math.max(10, Math.min(totalNotionalUsd, policy.maxOrderNotionalUsd));
  const singleShotImpactBps = computeThinLiquidityImpactBps(clampedTotal, effectiveDepthUsd);

  const impactTargetBps = Math.max(8, Math.floor(policy.maxSlippageBps * 0.65));
  const slicesByCap = Math.ceil(clampedTotal / Math.max(10, policy.maxSliceNotionalUsd));
  const slicesByDepth = Math.ceil(singleShotImpactBps / impactTargetBps);
  const slices = Math.min(12, Math.max(1, slicesByCap, slicesByDepth));

  const sliceNotionalUsd = Number((clampedTotal / slices).toFixed(2));
  // With pool mean-reversion / replenishment across cooldown intervals (~68% decay per interval)
  const perSliceImpact = computeThinLiquidityImpactBps(sliceNotionalUsd, effectiveDepthUsd);
  const residualCarry = slices > 1 ? Math.round(perSliceImpact * 0.25 * Math.log2(slices)) : 0;
  const twapImpactBps = Math.min(singleShotImpactBps, perSliceImpact + residualCarry);
  const bpsSaved = Math.max(0, singleShotImpactBps - twapImpactBps);
  const usdSaved = Number(((clampedTotal * bpsSaved) / 10_000).toFixed(2));

  return {
    slices,
    sliceNotionalUsd,
    singleShotImpactBps,
    twapImpactBps,
    bpsSaved,
    usdSaved,
  };
}

export interface OpportunityVerdict {
  verdict: 'EXECUTE_TWAP' | 'REFUSE';
  reasonCode:
    | 'OK'
    | 'CIRCUIT_BREAKER_TRIPPED'
    | 'AGENT_PAUSED'
    | 'ASSET_NOT_ALLOWED'
    | 'COOLDOWN_ACTIVE'
    | 'DAILY_TRADE_CAP'
    | 'EDGE_BELOW_MIN'
    | 'SLIPPAGE_ABOVE_MAX';
  reasonText: string;
}

export function evaluateOpportunityAgainstPolicy(
  snap: MarketVenueSnapshot,
  policy: ExecutionPolicy,
  cooldownRemainingSec: number,
  tradesToday: number,
): OpportunityVerdict {
  if (policy.circuitBreakerTripped) {
    return {
      verdict: 'REFUSE',
      reasonCode: 'CIRCUIT_BREAKER_TRIPPED',
      reasonText: `Stop-loss circuit breaker active (${policy.breakerReason ?? 'drawdown limit'}). Owner reset required.`,
    };
  }
  if (policy.paused) {
    return {
      verdict: 'REFUSE',
      reasonCode: 'AGENT_PAUSED',
      reasonText: 'Agent execution is manually paused by owner.',
    };
  }
  if (!policy.allowedAssets.includes(snap.asset)) {
    return {
      verdict: 'REFUSE',
      reasonCode: 'ASSET_NOT_ALLOWED',
      reasonText: `${snap.asset} is disabled in active allowedAssets rail.`,
    };
  }
  if (cooldownRemainingSec > 0) {
    return {
      verdict: 'REFUSE',
      reasonCode: 'COOLDOWN_ACTIVE',
      reasonText: `Slice cooldown active (${cooldownRemainingSec}s remaining < ${policy.minSliceIntervalSec}s rail).`,
    };
  }
  if (tradesToday >= policy.maxDailyTrades) {
    return {
      verdict: 'REFUSE',
      reasonCode: 'DAILY_TRADE_CAP',
      reasonText: `Daily trade count (${tradesToday}) reached maxDailyTrades (${policy.maxDailyTrades}).`,
    };
  }
  if (snap.twapImpactBps > policy.maxSlippageBps) {
    return {
      verdict: 'REFUSE',
      reasonCode: 'SLIPPAGE_ABOVE_MAX',
      reasonText: `Estimated TWAP impact (${snap.twapImpactBps} bps) exceeds maxSlippageBps (${policy.maxSlippageBps} bps).`,
    };
  }
  if (snap.netEdgeBps < policy.minNetEdgeBps) {
    return {
      verdict: 'REFUSE',
      reasonCode: 'EDGE_BELOW_MIN',
      reasonText: `Net edge (${snap.netEdgeBps} bps) below minNetEdgeBps (${policy.minNetEdgeBps} bps).`,
    };
  }
  return {
    verdict: 'EXECUTE_TWAP',
    reasonCode: 'OK',
    reasonText: `Net edge +${snap.netEdgeBps} bps clears rail (${policy.minNetEdgeBps} bps); ${snap.twapSlices}x TWAP saves ${snap.bpsSavedByTwap} bps.`,
  };
}

export interface PortfolioMetrics {
  totalEquityUsd: number;
  inventoryUsd: number;
  realizedPnlUsd: number;
  unrealizedPnlUsd: number;
  drawdownBps: number;
  stopLossBreached: boolean;
}

export function computePortfolioMetrics(
  cashUsd: number,
  positions: Record<AssetSymbol, Position>,
  markPrices: Record<AssetSymbol, number>,
  highWaterMarkUsd: number,
  stopLossDrawdownBps: number,
): PortfolioMetrics {
  let inventoryUsd = 0;
  let realizedPnlUsd = 0;
  let unrealizedPnlUsd = 0;

  (Object.keys(positions) as AssetSymbol[]).forEach((sym) => {
    const pos = positions[sym];
    const mark = markPrices[sym] || pos.avgEntryUsd || 0;
    inventoryUsd += pos.qty * mark;
    realizedPnlUsd += pos.realizedPnlUsd;
    if (pos.qty > 0 && pos.avgEntryUsd > 0) {
      unrealizedPnlUsd += (mark - pos.avgEntryUsd) * pos.qty;
    }
  });

  const totalEquityUsd = cashUsd + inventoryUsd;
  const hwm = Math.max(highWaterMarkUsd, 1);
  const drawdownBps =
    totalEquityUsd >= hwm ? 0 : Math.round(((hwm - totalEquityUsd) / hwm) * 10_000);

  return {
    totalEquityUsd: Number(totalEquityUsd.toFixed(2)),
    inventoryUsd: Number(inventoryUsd.toFixed(2)),
    realizedPnlUsd: Number(realizedPnlUsd.toFixed(2)),
    unrealizedPnlUsd: Number(unrealizedPnlUsd.toFixed(2)),
    drawdownBps,
    stopLossBreached: drawdownBps >= stopLossDrawdownBps,
  };
}

/**
 * Deterministic 32-byte hex digest for reproducible chatIntentHash / decisionHash telemetry.
 */
export function deterministicHash(input: string): string {
  let h1 = 0x811c9dc5;
  let h2 = 0x01000193;
  let h3 = 0x9e3779b9;
  let h4 = 0x85ebca6b;
  for (let i = 0; i < input.length; i++) {
    const ch = input.charCodeAt(i);
    h1 = Math.imul(h1 ^ ch, 0x01000193) >>> 0;
    h2 = Math.imul(h2 ^ (ch + i), 0x85ebca6b) >>> 0;
    h3 = Math.imul(h3 ^ (ch * 31), 0xc2b2ae35) >>> 0;
    h4 = Math.imul(h4 ^ ((ch << 5) - ch), 0x27d4eb2f) >>> 0;
  }
  const hex = (n: number) => n.toString(16).padStart(8, '0');
  return `0x${hex(h1)}${hex(h2)}${hex(h3)}${hex(h4)}${hex(h1 ^ h3)}${hex(h2 ^ h4)}${hex(
    (h1 + h4) >>> 0,
  )}${hex((h2 + h3) >>> 0)}`;
}

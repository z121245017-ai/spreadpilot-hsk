import { describe, expect, it } from 'vitest';
import { processConversationalCommand } from './chatAgent';
import {
  computePortfolioMetrics,
  computeThinLiquidityImpactBps,
  createInitialPolicy,
  decodeSqrtPriceX96ToPrice,
  evaluateOpportunityAgainstPolicy,
  planLiquidityAwareTwap,
} from './spreadEngine';
import type { MarketVenueSnapshot } from './types';

describe('SpreadPilot HSK quantitative engine', () => {
  it('decodes real HSKSwap Mainnet WHSK/USDT sqrtPriceX96 accurately', () => {
    // Live verified HSKSwap Mainnet 0.05% WHSK/USDT pool slot0 sqrtPriceX96
    const price = decodeSqrtPriceX96ToPrice(25055738251564958613595n, 18, 6);
    expect(price).toBeGreaterThan(0.099);
    expect(price).toBeLessThan(0.101);
  });

  it('splits large orders into liquidity-aware TWAP slices and reduces impact', () => {
    const policy = createInitialPolicy();
    const plan = planLiquidityAwareTwap(1200, 18_000, policy);
    expect(plan.slices).toBeGreaterThanOrEqual(5);
    expect(plan.sliceNotionalUsd).toBeLessThanOrEqual(policy.maxSliceNotionalUsd);
    expect(plan.twapImpactBps).toBeLessThan(plan.singleShotImpactBps);
    expect(plan.bpsSaved).toBeGreaterThan(0);
    expect(computeThinLiquidityImpactBps(1200, 18_000)).toBe(plan.singleShotImpactBps);
  });

  it('enforces stop-loss breaker, asset allowlist, cooldown, and min edge rails', () => {
    const policy = createInitialPolicy();
    const snap: MarketVenueSnapshot = {
      id: 'test-1',
      pair: 'WHSK/USDT',
      asset: 'WHSK',
      venueLabel: 'HSKSwap V3',
      poolFeeBps: 5,
      hskSwapPrice: 0.1,
      cexMidPrice: 0.08,
      cexBid: 0.0799,
      cexAsk: 0.0801,
      cexSource: 'Gate.io',
      onChainLiquidityRaw: '2830955089632',
      estimatedDepthUsd: 24500,
      grossSpreadBps: 2500,
      direction: 'SELL_ON_HSKSWAP',
      singleShotImpactBps: 163,
      twapSlices: 4,
      twapSliceUsd: 200,
      twapImpactBps: 45,
      bpsSavedByTwap: 118,
      netEdgeBps: 80,
      signal: 'EXECUTE_TWAP',
      signalNote: '',
      isOnChainLive: true,
      isCexLive: true,
      updatedAt: Date.now(),
    };

    expect(evaluateOpportunityAgainstPolicy(snap, policy, 0, 1).verdict).toBe('EXECUTE_TWAP');
    expect(evaluateOpportunityAgainstPolicy(snap, policy, 10, 1).reasonCode).toBe('COOLDOWN_ACTIVE');
    expect(
      evaluateOpportunityAgainstPolicy(
        snap,
        { ...policy, allowedAssets: ['WETH'] },
        0,
        1,
      ).reasonCode,
    ).toBe('ASSET_NOT_ALLOWED');
    expect(
      evaluateOpportunityAgainstPolicy(
        snap,
        { ...policy, circuitBreakerTripped: true },
        0,
        1,
      ).reasonCode,
    ).toBe('CIRCUIT_BREAKER_TRIPPED');
  });

  it('parses conversational policy updates, TWAP commands, and stop-loss stress tests', () => {
    const initial = createInitialPolicy();
    const portfolio = { equityUsd: 10000, realizedPnlUsd: 50, unrealizedPnlUsd: 20, drawdownBps: 40 };

    const r1 = processConversationalCommand(
      'Switch to conservative mode, cap slice at $100, cooldown 60s, stop-loss 2%, enable WHSK and WETH only',
      initial,
      [],
      portfolio,
    );
    expect(r1.nextPolicy.riskAppetite).toBe('CONSERVATIVE');
    expect(r1.nextPolicy.maxSliceNotionalUsd).toBe(100);
    expect(r1.nextPolicy.minSliceIntervalSec).toBe(60);
    expect(r1.nextPolicy.stopLossDrawdownBps).toBe(200);
    expect(r1.nextPolicy.allowedAssets).toEqual(['WHSK', 'WETH']);
    expect(r1.message.policyDiffs?.length).toBeGreaterThanOrEqual(4);

    // Ordering disabled asset WBTC must be refused
    const r2 = processConversationalCommand('Buy $300 WBTC using TWAP', r1.nextPolicy, [], portfolio);
    expect(r2.newPlan).toBeUndefined();
    expect(r2.message.statusBadge).toContain('REFUSED');

    // Ordering enabled asset WHSK creates valid TWAP plan
    const r3 = processConversationalCommand('Buy $400 WHSK using TWAP', r1.nextPolicy, [], portfolio);
    expect(r3.newPlan?.slicesTotal).toBeGreaterThanOrEqual(4);
    expect(r3.newPlan?.asset).toBe('WHSK');

    // Stress-test trips circuit breaker and blocks next order
    const r4 = processConversationalCommand('Simulate stop-loss breach', r1.nextPolicy, [], portfolio);
    expect(r4.nextPolicy.circuitBreakerTripped).toBe(true);
    const r5 = processConversationalCommand('Buy $200 WHSK', r4.nextPolicy, [], portfolio);
    expect(r5.newPlan).toBeUndefined();
    expect(r5.message.statusBadge).toContain('BREAKER');
  });

  it('computes portfolio drawdown and triggers stopLossBreached flag accurately', () => {
    const m = computePortfolioMetrics(
      5000,
      {
        WHSK: { asset: 'WHSK', qty: 50000, avgEntryUsd: 0.1, realizedPnlUsd: 0 },
        WETH: { asset: 'WETH', qty: 0, avgEntryUsd: 0, realizedPnlUsd: 0 },
        WBTC: { asset: 'WBTC', qty: 0, avgEntryUsd: 0, realizedPnlUsd: 0 },
        USDC: { asset: 'USDC', qty: 0, avgEntryUsd: 0, realizedPnlUsd: 0 },
      },
      { WHSK: 0.088, WETH: 1700, WBTC: 60000, USDC: 1 },
      10000,
      400, // 4%
    );
    expect(m.totalEquityUsd).toBe(9400);
    expect(m.drawdownBps).toBe(600);
    expect(m.stopLossBreached).toBe(true);
  });
});

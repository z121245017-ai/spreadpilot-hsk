import { formatDeploymentTarget } from './deployments';
import {
  RISK_PRESETS,
  deterministicHash,
  planLiquidityAwareTwap,
} from './spreadEngine';
import type {
  AssetSymbol,
  ChatMessage,
  ExecutionPolicy,
  MarketVenueSnapshot,
  PolicyDiff,
  RiskAppetite,
  TwapPlan,
} from './types';

export interface AgentCommandResult {
  nextPolicy: ExecutionPolicy;
  newPlan?: TwapPlan;
  simulateStopLossBreach?: boolean;
  resetBreaker?: boolean;
  triggerImmediateSlice?: boolean;
  message: ChatMessage;
}

function formatAssets(list: AssetSymbol[]): string {
  return list.length > 0 ? list.join(', ') : 'NONE';
}

export function processConversationalCommand(
  rawInput: string,
  currentPolicy: ExecutionPolicy,
  snapshots: MarketVenueSnapshot[],
  portfolioSummary: { equityUsd: number; realizedPnlUsd: number; unrealizedPnlUsd: number; drawdownBps: number },
): AgentCommandResult {
  const input = rawInput.trim();
  const lower = input.toLowerCase();
  let next: ExecutionPolicy = {
    ...currentPolicy,
    allowedAssets: [...currentPolicy.allowedAssets],
  };
  const diffs: PolicyDiff[] = [];

  const recordDiff = (field: string, before: string, after: string) => {
    if (before !== after) diffs.push({ field, before, after });
  };

  // 1. Stop-loss simulation / circuit breaker reset / pause / resume
  if (/simulat|stress|trigger\s+stop|测试止损|触发熔断|模拟止损/.test(lower)) {
    const intentHash = deterministicHash(`SIM_BREACH:${input}:${Date.now()}`);
    return {
      nextPolicy: {
        ...next,
        circuitBreakerTripped: true,
        breakerReason: `Mark-to-market drawdown exceeded ${next.stopLossDrawdownBps / 100}% stop-loss rail`,
      },
      simulateStopLossBreach: true,
      message: {
        id: `msg-${Date.now()}`,
        role: 'agent',
        timestamp: Date.now(),
        statusBadge: 'STOP-LOSS BREAKER TRIPPED',
        text: `Simulated a -${(next.stopLossDrawdownBps / 100 + 0.6).toFixed(
          1,
        )}% mark-to-market shock. On-chain SpreadPilotVault circuit breaker tripped immediately — all active TWAP slices are now blocked until owner calls resetCircuitBreaker().`,
        policyDiffs: [
          { field: 'circuitBreaker', before: 'ARMED', after: 'TRIPPED (LOCKED)' },
        ],
        calldataPreview: {
          target: formatDeploymentTarget('vault'),
          fnName: 'reportMarkToMarketAndCheckStopLoss(uint256)',
          argsSummary: `markEquity=${Math.round(portfolioSummary.equityUsd * 0.94)}e6 (< stopLossFloor)`,
          intentHash,
        },
      },
    };
  }

  if (/reset\s*(circuit|breaker)|unfreeze|恢复熔断|解除熔断/.test(lower)) {
    const intentHash = deterministicHash(`RESET_BREAKER:${input}:${Date.now()}`);
    next.circuitBreakerTripped = false;
    next.breakerReason = null;
    next.paused = false;
    return {
      nextPolicy: next,
      resetBreaker: true,
      message: {
        id: `msg-${Date.now()}`,
        role: 'agent',
        timestamp: Date.now(),
        statusBadge: 'BREAKER RESET · ARMED',
        text: 'Owner circuit-breaker reset confirmed. High-water mark re-anchored and autonomous spread monitoring is armed again.',
        policyDiffs: [
          { field: 'circuitBreaker', before: 'TRIPPED', after: 'ARMED' },
          ...(currentPolicy.paused ? [{ field: 'paused', before: 'true', after: 'false' }] : []),
        ],
        calldataPreview: {
          target: formatDeploymentTarget('vault'),
          fnName: 'resetCircuitBreaker()',
          argsSummary: 'owner-only high-water mark reset',
          intentHash,
        },
      },
    };
  }

  if (/\bpause\b|stop\s+trading|暂停/.test(lower)) {
    recordDiff('paused', String(next.paused), 'true');
    next.paused = true;
  } else if (/\bresume\b|unpause|继续交易|恢复交易/.test(lower)) {
    recordDiff('paused', String(next.paused), 'false');
    next.paused = false;
  }

  // 2. Risk appetite presets
  let chosenPreset: RiskAppetite | null = null;
  if (/conservative|保守|低风险/.test(lower)) chosenPreset = 'CONSERVATIVE';
  else if (/aggressive|激进|高风险/.test(lower)) chosenPreset = 'AGGRESSIVE';
  else if (/balanced|均衡|中等风险/.test(lower)) chosenPreset = 'BALANCED';

  if (chosenPreset) {
    const preset = RISK_PRESETS[chosenPreset];
    recordDiff('riskAppetite', next.riskAppetite, preset.riskAppetite);
    recordDiff('maxSlice', `$${next.maxSliceNotionalUsd}`, `$${preset.maxSliceNotionalUsd}`);
    recordDiff('cooldown', `${next.minSliceIntervalSec}s`, `${preset.minSliceIntervalSec}s`);
    recordDiff('minEdge', `${next.minNetEdgeBps} bps`, `${preset.minNetEdgeBps} bps`);
    recordDiff(
      'stopLoss',
      `${(next.stopLossDrawdownBps / 100).toFixed(1)}%`,
      `${(preset.stopLossDrawdownBps / 100).toFixed(1)}%`,
    );
    next = { ...next, ...preset };
  }

  // 3. Explicit parameter overrides (position size / slice cap / frequency / stop-loss / edge / slippage / daily cap)
  const sliceMatch = lower.match(/(?:slice|position|size|仓位|单片)[^\d$]{0,18}\$?\s*(\d+(?:\.\d+)?)/);
  if (sliceMatch && !/(?:buy|sell|long|short|twap|买|卖)\s+\$?\s*\d+/.test(lower.slice(Math.max(0, (sliceMatch.index ?? 0) - 10), (sliceMatch.index ?? 0) + 18))) {
    const val = Math.min(2000, Math.max(25, Math.round(Number(sliceMatch[1]))));
    recordDiff('maxSlice', `$${next.maxSliceNotionalUsd}`, `$${val}`);
    next.maxSliceNotionalUsd = val;
    if (next.maxOrderNotionalUsd < val) next.maxOrderNotionalUsd = val * 4;
  }

  const maxOrderMatch = lower.match(/(?:max\s+order|order\s+cap|单笔上限)[^\d$]{0,16}\$?\s*(\d+)/);
  if (maxOrderMatch) {
    const val = Math.min(10000, Math.max(50, Number(maxOrderMatch[1])));
    recordDiff('maxOrder', `$${next.maxOrderNotionalUsd}`, `$${val}`);
    next.maxOrderNotionalUsd = val;
  }

  const freqMatch = lower.match(/(?:cooldown|every|interval|frequency|频率|冷却)[^\d]{0,16}(\d+)\s*(?:s|sec|second|秒)?/);
  if (freqMatch) {
    const val = Math.min(3600, Math.max(5, Number(freqMatch[1])));
    recordDiff('cooldown', `${next.minSliceIntervalSec}s`, `${val}s`);
    next.minSliceIntervalSec = val;
  }

  const slMatch = lower.match(/(?:stop[\s-]*loss|drawdown|止损|回撤)[^\d]{0,16}(\d+(?:\.\d+)?)\s*%?/);
  if (slMatch) {
    const pct = Math.min(25, Math.max(0.5, Number(slMatch[1])));
    const bps = Math.round(pct * 100);
    recordDiff('stopLoss', `${(next.stopLossDrawdownBps / 100).toFixed(1)}%`, `${pct.toFixed(1)}%`);
    next.stopLossDrawdownBps = bps;
  }

  const edgeMatch = lower.match(/(?:min\s*edge|spread|价差)[^\d]{0,16}(\d+)\s*(?:bps)?/);
  if (edgeMatch) {
    const bps = Math.min(300, Math.max(2, Number(edgeMatch[1])));
    recordDiff('minEdge', `${next.minNetEdgeBps} bps`, `${bps} bps`);
    next.minNetEdgeBps = bps;
  }

  const slipMatch = lower.match(/(?:slippage|滑点)[^\d]{0,16}(\d+)\s*(?:bps)?/);
  if (slipMatch) {
    const bps = Math.min(300, Math.max(5, Number(slipMatch[1])));
    recordDiff('maxSlippage', `${next.maxSlippageBps} bps`, `${bps} bps`);
    next.maxSlippageBps = bps;
  }

  const dailyLossMatch = lower.match(/(?:daily\s*loss|日亏)[^\d$]{0,16}\$?\s*(\d+)/);
  if (dailyLossMatch) {
    const usd = Math.min(5000, Math.max(20, Number(dailyLossMatch[1])));
    recordDiff('dailyLossCap', `$${next.dailyLossLimitUsd}`, `$${usd}`);
    next.dailyLossLimitUsd = usd;
  }

  const maxTradesMatch = lower.match(/(?:max\s*(\d+)\s*trades|(\d+)\s*trades\s*(?:per|\/)\s*day)/);
  if (maxTradesMatch) {
    const cnt = Math.min(200, Math.max(1, Number(maxTradesMatch[1] || maxTradesMatch[2])));
    recordDiff('maxDailyTrades', String(next.maxDailyTrades), String(cnt));
    next.maxDailyTrades = cnt;
  }

  // 4. Target asset allowlist updates
  const allAssets: AssetSymbol[] = ['WHSK', 'WETH', 'WBTC', 'USDC'];
  const mentionedAssets = allAssets.filter((sym) => {
    const short = sym.startsWith('W') ? sym.slice(1) : sym;
    return new RegExp(`\\b(?:${sym}|${short})\\b`, 'i').test(input);
  });

  if (/(?:all\s+assets|enable\s+all|全部资产)/.test(lower)) {
    recordDiff('allowedAssets', formatAssets(next.allowedAssets), formatAssets(allAssets));
    next.allowedAssets = [...allAssets];
  } else if (/(?:only|restrict|allowlist|仅交易|只允许)/.test(lower) && mentionedAssets.length > 0) {
    recordDiff('allowedAssets', formatAssets(next.allowedAssets), formatAssets(mentionedAssets));
    next.allowedAssets = mentionedAssets;
  } else if (/(?:disable|remove|ban|禁用|移除)/.test(lower) && mentionedAssets.length > 0) {
    const filtered = next.allowedAssets.filter((a) => !mentionedAssets.includes(a));
    recordDiff('allowedAssets', formatAssets(next.allowedAssets), formatAssets(filtered));
    next.allowedAssets = filtered;
  } else if (/(?:enable|add|启用)/.test(lower) && mentionedAssets.length > 0) {
    const merged = Array.from(new Set([...next.allowedAssets, ...mentionedAssets]));
    recordDiff('allowedAssets', formatAssets(next.allowedAssets), formatAssets(merged));
    next.allowedAssets = merged;
  }

  // 5. Direct TWAP / Spread Execution Command (e.g. "buy $400 of WHSK using TWAP")
  const orderMatch = lower.match(/\b(buy|sell|arb|arbitrage|long|short|买入|卖出|套利)\b/);
  const amountMatch = input.match(/\$\s*(\d+(?:\.\d+)?)|(\d+(?:\.\d+)?)\s*(?:usd|usdt|usdc)/i);

  if (orderMatch && (amountMatch || /arb|arbitrage|套利/.test(lower))) {
    const side: 'BUY' | 'SELL' = /sell|short|卖出/.test(orderMatch[1]) ? 'SELL' : 'BUY';
    const targetAsset: AssetSymbol = mentionedAssets[0] ?? 'WHSK';
    const requestedUsd = amountMatch
      ? Number(amountMatch[1] || amountMatch[2])
      : Math.min(next.maxOrderNotionalUsd, next.maxSliceNotionalUsd * 3);

    const intentHash = deterministicHash(`TWAP:${side}:${targetAsset}:${requestedUsd}:${Date.now()}`);

    if (next.circuitBreakerTripped) {
      return {
        nextPolicy: next,
        message: {
          id: `msg-${Date.now()}`,
          role: 'agent',
          timestamp: Date.now(),
          statusBadge: 'REFUSED · BREAKER LOCKED',
          text: `Order REFUSED on-chain: Stop-loss circuit breaker is tripped (${next.breakerReason ?? 'drawdown limit'}). Say "reset circuit breaker" after reviewing risk to unlock trading.`,
          policyDiffs: diffs.length > 0 ? diffs : undefined,
        },
      };
    }

    if (!next.allowedAssets.includes(targetAsset)) {
      return {
        nextPolicy: next,
        message: {
          id: `msg-${Date.now()}`,
          role: 'agent',
          timestamp: Date.now(),
          statusBadge: 'REFUSED · ASSET RAIL',
          text: `Order REFUSED: ${targetAsset} is currently excluded from allowedAssets (${formatAssets(next.allowedAssets)}). Enable ${targetAsset} first to route orders.`,
          policyDiffs: diffs.length > 0 ? diffs : undefined,
        },
      };
    }

    const snap = snapshots.find((s) => s.asset === targetAsset) ?? snapshots[0];
    const calc = planLiquidityAwareTwap(requestedUsd, snap?.estimatedDepthUsd ?? 24_000, next);
    const totalClamped = Math.min(requestedUsd, next.maxOrderNotionalUsd);

    const newPlan: TwapPlan = {
      id: `TWAP-${Math.floor(1000 + Math.random() * 9000)}`,
      asset: targetAsset,
      pair: `${targetAsset}/USDT`,
      side,
      totalNotionalUsd: totalClamped,
      sliceNotionalUsd: calc.sliceNotionalUsd,
      slicesTotal: calc.slices,
      slicesExecuted: 0,
      minNetEdgeBps: next.minNetEdgeBps,
      maxSlippageBps: next.maxSlippageBps,
      singleShotImpactBps: calc.singleShotImpactBps,
      twapImpactBps: calc.twapImpactBps,
      bpsSaved: calc.bpsSaved,
      avgFillPrice: snap?.hskSwapPrice ?? 0.1,
      status: 'ACTIVE',
      createdAt: Date.now(),
      lastSliceAt: 0,
      decisionHash: intentHash,
    };

    const capNote =
      requestedUsd > next.maxOrderNotionalUsd
        ? ` (clamped from $${requestedUsd} to policy maxOrder $${next.maxOrderNotionalUsd})`
        : '';

    return {
      nextPolicy: next,
      newPlan,
      triggerImmediateSlice: true,
      message: {
        id: `msg-${Date.now()}`,
        role: 'agent',
        timestamp: Date.now(),
        statusBadge: `TWAP STAGED · ${calc.slices} SLICES`,
        text: `Staged ${side} $${totalClamped} ${targetAsset}/USDT${capNote}. HSKSwap liquidity lens split this into ${calc.slices} × $${calc.sliceNotionalUsd} slices spaced ${next.minSliceIntervalSec}s apart, cutting expected thin-pool impact from ${calc.singleShotImpactBps} bps → ${calc.twapImpactBps} bps (saving ${calc.bpsSaved} bps / ~$${calc.usdSaved}).`,
        policyDiffs: diffs.length > 0 ? diffs : undefined,
        planSummary: {
          asset: targetAsset,
          side,
          totalUsd: totalClamped,
          slices: calc.slices,
          sliceUsd: calc.sliceNotionalUsd,
          singleImpactBps: calc.singleShotImpactBps,
          twapImpactBps: calc.twapImpactBps,
          bpsSaved: calc.bpsSaved,
        },
        calldataPreview: {
          target: formatDeploymentTarget('vault'),
          fnName: 'createTwapPlan(address,address,uint24,uint256,uint16,int32,uint16,uint256)',
          argsSummary: `${targetAsset}/USDT · total=$${totalClamped} · ${calc.slices} slices · maxSlip=${next.maxSlippageBps}bps`,
          intentHash,
        },
      },
    };
  }

  // 6. Status / PnL / Spread scan queries
  if (diffs.length === 0) {
    const best = [...snapshots].sort((a, b) => b.netEdgeBps - a.netEdgeBps)[0];
    const intentHash = deterministicHash(`QUERY:${input}:${Date.now()}`);
    if (/position|pnl|portfolio|持仓|盈亏|状态/.test(lower)) {
      return {
        nextPolicy: next,
        message: {
          id: `msg-${Date.now()}`,
          role: 'agent',
          timestamp: Date.now(),
          statusBadge: 'PORTFOLIO TELEMETRY',
          text: `Live Equity: $${portfolioSummary.equityUsd.toFixed(2)} | Realized PnL: ${
            portfolioSummary.realizedPnlUsd >= 0 ? '+' : ''
          }$${portfolioSummary.realizedPnlUsd.toFixed(2)} | Unrealized PnL: ${
            portfolioSummary.unrealizedPnlUsd >= 0 ? '+' : ''
          }$${portfolioSummary.unrealizedPnlUsd.toFixed(2)} | Drawdown: ${(
            portfolioSummary.drawdownBps / 100
          ).toFixed(2)}% / ${(next.stopLossDrawdownBps / 100).toFixed(1)}% stop-loss cap. Active rails: ${
            next.riskAppetite
          }, maxSlice $${next.maxSliceNotionalUsd}, cooldown ${next.minSliceIntervalSec}s, assets [${formatAssets(
            next.allowedAssets,
          )}].`,
        },
      };
    }

    return {
      nextPolicy: next,
      message: {
        id: `msg-${Date.now()}`,
        role: 'agent',
        timestamp: Date.now(),
        statusBadge: 'SPREAD SCANNER',
        text: best
          ? `Top live dislocation: ${best.pair} on ${best.venueLabel} — gross spread ${best.grossSpreadBps} bps, net executable edge +${best.netEdgeBps} bps after ${best.poolFeeBps} bps V3 fee & ${best.twapImpactBps} bps TWAP impact (saving ${best.bpsSavedByTwap} bps vs single-shot). Try saying "Buy $400 WHSK using TWAP" or "Switch to conservative, cap slice $120, stop-loss 2.5%".`
          : 'Live feeds syncing. Try commands like "Switch to conservative", "Buy $400 WHSK TWAP", "Enable WHSK and WETH only", or "Simulate stop-loss breach".',
        calldataPreview: {
          target: formatDeploymentTarget('lens'),
          fnName: 'estimateSlicePlan(uint256,uint128,uint24,uint16,uint256)',
          argsSummary: `read-only view · top=${best?.pair ?? 'WHSK/USDT'}`,
          intentHash,
        },
      },
    };
  }

  // 7. Policy update response
  const intentHash = deterministicHash(`POLICY:${JSON.stringify(diffs)}:${Date.now()}`);
  return {
    nextPolicy: next,
    message: {
      id: `msg-${Date.now()}`,
      role: 'agent',
      timestamp: Date.now(),
      statusBadge: `POLICY UPDATED · ${diffs.length} RAIL${diffs.length > 1 ? 'S' : ''}`,
      text: `Updated on-chain risk rails (${diffs
        .map((d) => `${d.field}: ${d.before} → ${d.after}`)
        .join(' · ')}). Every subsequent autonomous TWAP slice will enforce these exact bounds atomically.`,
      policyDiffs: diffs,
      calldataPreview: {
        target: formatDeploymentTarget('vault'),
        fnName: 'updatePolicy(ExecutionPolicy,bytes32)',
        argsSummary: `mode=${next.riskAppetite}, maxSlice=$${next.maxSliceNotionalUsd}, cd=${next.minSliceIntervalSec}s, sl=${next.stopLossDrawdownBps}bps`,
        intentHash,
      },
    },
  };
}

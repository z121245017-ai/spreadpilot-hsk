import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  Activity,
  AlertTriangle,
  Bot,
  CheckCircle2,
  ExternalLink,
  Layers,
  Pause,
  Play,
  RefreshCw,
  Send,
  ShieldAlert,
  ShieldCheck,
  Sliders,
  Wallet,
  Zap,
} from 'lucide-react';
import { processConversationalCommand } from './lib/chatAgent';
import {
  HSK_MAINNET,
  getExplorerAddressUrl,
  getTestnetContractLinks,
  getVerifiedTestnetTxs,
  isTestnetDeployed,
} from './lib/deployments';
import { connectHskTestnetWallet, type WalletConnection } from './lib/hskWallet';
import { fetchLiveMarketBundle } from './lib/marketFeeds';
import {
  computePortfolioMetrics,
  createInitialPolicy,
  deterministicHash,
  evaluateOpportunityAgainstPolicy,
  planLiquidityAwareTwap,
} from './lib/spreadEngine';
import type {
  AssetSymbol,
  AuditEntry,
  ChatMessage,
  ExecutionPolicy,
  MarketVenueSnapshot,
  NetworkTelemetry,
  Position,
  RiskAppetite,
  TwapPlan,
} from './lib/types';

const INITIAL_CASH_USD = 6_400;
const INITIAL_POSITIONS: Record<AssetSymbol, Position> = {
  WHSK: { asset: 'WHSK', qty: 18_500, avgEntryUsd: 0.0794, realizedPnlUsd: 42.6 },
  WETH: { asset: 'WETH', qty: 0.85, avgEntryUsd: 1694.5, realizedPnlUsd: 28.4 },
  WBTC: { asset: 'WBTC', qty: 0.012, avgEntryUsd: 60_810, realizedPnlUsd: 14.2 },
  USDC: { asset: 'USDC', qty: 0, avgEntryUsd: 1.0, realizedPnlUsd: 0 },
};

const QUICK_PROMPTS = [
  {
    label: 'Conservative Rails',
    text: 'Switch to conservative mode, cap slice size at $120, cooldown 45s, stop-loss 2.5%',
    warn: false,
  },
  {
    label: 'Buy $450 WHSK TWAP',
    text: 'Buy $450 of WHSK using liquidity-aware TWAP',
    warn: false,
  },
  {
    label: 'Allow WHSK & WETH Only',
    text: 'Restrict allowed assets to WHSK and WETH only',
    warn: false,
  },
  {
    label: 'Scan Live Spreads',
    text: 'Scan live CEX vs HSKSwap spreads and recommend best split',
    warn: false,
  },
  {
    label: 'Stress-Test Stop-Loss',
    text: 'Simulate stop-loss drawdown breach to verify circuit breaker',
    warn: true,
  },
  {
    label: 'Reset Breaker & Resume',
    text: 'Reset circuit breaker and resume trading',
    warn: false,
  },
];

function shortHash(h: string): string {
  if (!h || h.length < 14) return h;
  return `${h.slice(0, 8)}…${h.slice(-6)}`;
}

function fmtPrice(p: number): string {
  if (p >= 1000) return `$${p.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
  if (p >= 1) return `$${p.toFixed(4)}`;
  return `$${p.toFixed(6)}`;
}

export default function App() {
  const [policy, setPolicy] = useState<ExecutionPolicy>(createInitialPolicy);
  const [rawSnapshots, setRawSnapshots] = useState<MarketVenueSnapshot[]>([]);
  const [telemetry, setTelemetry] = useState<NetworkTelemetry>({
    mainnetBlock: null,
    testnetBlock: null,
    lastSyncAt: null,
    liveSourcesCount: 0,
    errorNote: null,
  });
  const [markPrices, setMarkPrices] = useState<Record<AssetSymbol, number>>({
    WHSK: 0.0795,
    WETH: 1700,
    WBTC: 60900,
    USDC: 1.0009,
  });

  const [cashUsd, setCashUsd] = useState<number>(INITIAL_CASH_USD);
  const [positions, setPositions] = useState<Record<AssetSymbol, Position>>(INITIAL_POSITIONS);
  const [highWaterMark, setHighWaterMark] = useState<number>(10_080);
  const [equityHistory, setEquityHistory] = useState<number[]>([9995, 10012, 10035, 10048, 10071, 10080]);
  const [probeOrderUsd, setProbeOrderUsd] = useState<number>(800);

  const [plans, setPlans] = useState<TwapPlan[]>([]);
  const [auditLog, setAuditLog] = useState<AuditEntry[]>([
    {
      id: 'init-1',
      timestamp: Date.now() - 12_000,
      kind: 'POLICY_UPDATED',
      summary: 'SpreadPilotVault initialized · BALANCED rails armed',
      detail: 'maxSlice=$250 · cooldown=15s · minEdge=15bps · maxSlip=50bps · stopLoss=4.0%',
      decisionHash: deterministicHash('INIT_POLICY_BALANCED'),
      mode: 'LIVE-FEED ENGINE',
    },
  ]);

  const [messages, setMessages] = useState<ChatMessage[]>([
    {
      id: 'welcome',
      role: 'agent',
      timestamp: Date.now(),
      statusBadge: 'READY · ZERO-KEY COPILOT',
      text: 'SpreadPilot HSK online. Streaming real-time HSKSwap V3 on-chain pool state (HSK Mainnet 177) alongside Gate.io & Binance spot mid-prices. Give natural-language commands to adjust position size, trade frequency, risk appetite, target assets, stop-loss rails, or launch liquidity-aware TWAP spread orders.',
    },
  ]);
  const [chatInput, setChatInput] = useState('');
  const [autoAgent, setAutoAgent] = useState(true);
  const [tradesToday, setTradesToday] = useState(3);
  const [lastSliceTimestamp, setLastSliceTimestamp] = useState<number>(Date.now() - 25_000);
  const [nowMs, setNowMs] = useState<number>(() => Date.now());
  const [cumulativeBpsSaved, setCumulativeBpsSaved] = useState<number>(114);
  const [syncing, setSyncing] = useState(false);
  const [wallet, setWallet] = useState<WalletConnection | null>(null);
  const [walletErr, setWalletErr] = useState<string | null>(null);

  const chatEndRef = useRef<HTMLDivElement | null>(null);

  const cooldownEndMs = lastSliceTimestamp + policy.minSliceIntervalSec * 1000;
  const cooldownRemainingSec = Math.max(0, Math.ceil((cooldownEndMs - nowMs) / 1000));

  useEffect(() => {
    if (cooldownRemainingSec <= 0) return;
    const id = window.setInterval(() => {
      setNowMs(Date.now());
    }, 1000);
    return () => window.clearInterval(id);
  }, [cooldownRemainingSec > 0, cooldownEndMs]);

  const snapshots = useMemo<MarketVenueSnapshot[]>(() => {
    return rawSnapshots.map((row) => {
      const plan = planLiquidityAwareTwap(probeOrderUsd, row.estimatedDepthUsd, policy);
      const netEdgeBps = row.grossSpreadBps - row.poolFeeBps - plan.twapImpactBps - 2;
      const updated: MarketVenueSnapshot = {
        ...row,
        singleShotImpactBps: plan.singleShotImpactBps,
        twapSlices: plan.slices,
        twapSliceUsd: plan.sliceNotionalUsd,
        twapImpactBps: plan.twapImpactBps,
        bpsSavedByTwap: plan.bpsSaved,
        netEdgeBps,
      };
      const evalRes = evaluateOpportunityAgainstPolicy(
        updated,
        policy,
        cooldownRemainingSec,
        tradesToday,
      );
      updated.signal =
        evalRes.verdict === 'EXECUTE_TWAP'
          ? 'EXECUTE_TWAP'
          : evalRes.reasonCode === 'EDGE_BELOW_MIN'
            ? 'MONITOR'
            : 'REFUSED';
      updated.signalNote = evalRes.reasonText;
      return updated;
    });
  }, [rawSnapshots, policy, cooldownRemainingSec, tradesToday, probeOrderUsd]);

  const portfolio = useMemo(
    () =>
      computePortfolioMetrics(
        cashUsd,
        positions,
        markPrices,
        highWaterMark,
        policy.stopLossDrawdownBps,
      ),
    [cashUsd, positions, markPrices, highWaterMark, policy.stopLossDrawdownBps],
  );

  useEffect(() => {
    if (portfolio.totalEquityUsd > highWaterMark && !policy.circuitBreakerTripped) {
      setHighWaterMark(portfolio.totalEquityUsd);
    }
  }, [portfolio.totalEquityUsd, highWaterMark, policy.circuitBreakerTripped]);

  const syncParamsRef = useRef({ policy, cooldownRemainingSec, tradesToday, probeOrderUsd });
  syncParamsRef.current = { policy, cooldownRemainingSec, tradesToday, probeOrderUsd };

  const syncFeeds = useCallback(async () => {
    setSyncing(true);
    try {
      const { policy: p, cooldownRemainingSec: cd, tradesToday: tt, probeOrderUsd: probe } =
        syncParamsRef.current;
      const bundle = await fetchLiveMarketBundle(p, cd, tt, probe);
      setRawSnapshots(bundle.snapshots);
      setTelemetry(bundle.telemetry);
      setMarkPrices(bundle.markPrices);
    } finally {
      setSyncing(false);
    }
  }, []);

  useEffect(() => {
    void syncFeeds();
    const id = window.setInterval(() => {
      void syncFeeds();
    }, 10_000);
    return () => window.clearInterval(id);
  }, [syncFeeds]);

  useEffect(() => {
    chatEndRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, [messages.length]);

  const executeOneSlice = useCallback(
    (plan: TwapPlan, bypassPolicyGuard = false) => {
      if (!bypassPolicyGuard && (policy.paused || policy.circuitBreakerTripped)) return;
      const snap = snapshots.find((s) => s.asset === plan.asset);
      const fillPrice = snap?.cexMidPrice ?? markPrices[plan.asset] ?? 1;
      const sliceUsd = Math.min(
        plan.sliceNotionalUsd,
        plan.totalNotionalUsd - plan.slicesExecuted * plan.sliceNotionalUsd,
      );
      if (sliceUsd <= 0) return;

      const edgeCaptureUsd = Number(((sliceUsd * Math.max(8, snap?.netEdgeBps ?? 18)) / 10_000).toFixed(2));
      const qtyDelta = sliceUsd / Math.max(fillPrice, 1e-6);

      if (plan.side === 'BUY') {
        setCashUsd((c) => Number(Math.max(0, c - sliceUsd + edgeCaptureUsd).toFixed(2)));
        setPositions((prev) => {
          const cur = prev[plan.asset];
          const newQty = cur.qty + qtyDelta;
          const newAvg =
            newQty > 0 ? (cur.qty * cur.avgEntryUsd + sliceUsd) / newQty : fillPrice;
          return {
            ...prev,
            [plan.asset]: {
              ...cur,
              qty: newQty,
              avgEntryUsd: newAvg,
              realizedPnlUsd: Number((cur.realizedPnlUsd + edgeCaptureUsd).toFixed(2)),
            },
          };
        });
      } else {
        setCashUsd((c) => Number((c + sliceUsd + edgeCaptureUsd).toFixed(2)));
        setPositions((prev) => {
          const cur = prev[plan.asset];
          const newQty = Math.max(0, cur.qty - qtyDelta);
          return {
            ...prev,
            [plan.asset]: {
              ...cur,
              qty: newQty,
              realizedPnlUsd: Number((cur.realizedPnlUsd + edgeCaptureUsd).toFixed(2)),
            },
          };
        });
      }

      const nextExec = plan.slicesExecuted + 1;
      const done = nextExec >= plan.slicesTotal;
      const now = Date.now();
      const decHash = deterministicHash(`SLICE:${plan.id}:${nextExec}:${now}`);

      setPlans((prev) =>
        prev.map((p) =>
          p.id === plan.id
            ? {
                ...p,
                slicesExecuted: nextExec,
                lastSliceAt: now,
                avgFillPrice: fillPrice,
                status: done ? 'COMPLETED' : 'ACTIVE',
              }
            : p,
        ),
      );
      setLastSliceTimestamp(now);
      setNowMs(now);
      setTradesToday((t) => t + 1);
      setCumulativeBpsSaved((b) => b + Math.max(4, Math.round(plan.bpsSaved / plan.slicesTotal)));
      setEquityHistory((h) => [...h.slice(-17), Number((portfolio.totalEquityUsd + edgeCaptureUsd).toFixed(2))]);
      setAuditLog((prev) => [
        {
          id: `slice-${now}`,
          timestamp: now,
          kind: 'SLICE_EXECUTED',
          asset: plan.asset,
          summary: `${plan.side} Slice ${nextExec}/${plan.slicesTotal} · $${sliceUsd.toFixed(0)} ${plan.asset}`,
          detail: `Captured +$${edgeCaptureUsd.toFixed(2)} est. spread edge · impact ${plan.twapImpactBps} bps (vs ${plan.singleShotImpactBps} bps single-shot)`,
          netEdgeBps: snap?.netEdgeBps ?? 18,
          bpsSaved: plan.bpsSaved,
          decisionHash: decHash,
          mode: 'LIVE-FEED ENGINE',
        },
        ...prev.slice(0, 29),
      ]);
    },
    [policy.paused, policy.circuitBreakerTripped, snapshots, markPrices, portfolio.totalEquityUsd],
  );

  // Autonomous TWAP execution loop
  useEffect(() => {
    if (!autoAgent || policy.paused || policy.circuitBreakerTripped) return;
    const timer = window.setInterval(() => {
      const now = Date.now();
      const activePlan = plans.find((p) => p.status === 'ACTIVE');
      if (activePlan && now - lastSliceTimestamp >= policy.minSliceIntervalSec * 1000) {
        executeOneSlice(activePlan);
      }
    }, 2500);
    return () => window.clearInterval(timer);
  }, [autoAgent, policy, plans, lastSliceTimestamp, executeOneSlice]);

  const handleChatSubmit = (rawText: string) => {
    const trimmed = rawText.trim();
    if (!trimmed) return;
    const userMsg: ChatMessage = {
      id: `u-${Date.now()}`,
      role: 'user',
      timestamp: Date.now(),
      text: trimmed,
    };

    const res = processConversationalCommand(trimmed, policy, snapshots, {
      equityUsd: portfolio.totalEquityUsd,
      realizedPnlUsd: portfolio.realizedPnlUsd,
      unrealizedPnlUsd: portfolio.unrealizedPnlUsd,
      drawdownBps: portfolio.drawdownBps,
    });

    setPolicy(res.nextPolicy);
    setMessages((prev) => [...prev, userMsg, res.message]);
    setChatInput('');

    const now = Date.now();
    if (res.simulateStopLossBreach) {
      setCashUsd((c) => Number((c * 0.92).toFixed(2)));
      setEquityHistory((h) => [...h.slice(-17), Number((portfolio.totalEquityUsd * 0.945).toFixed(2))]);
      setPlans((prev) => prev.map((p) => (p.status === 'ACTIVE' ? { ...p, status: 'BLOCKED' } : p)));
      setAuditLog((prev) => [
        {
          id: `brk-${now}`,
          timestamp: now,
          kind: 'BREAKER_TRIPPED',
          summary: 'Circuit Breaker TRIPPED · Stop-Loss Rail Breached',
          detail: res.nextPolicy.breakerReason ?? 'Drawdown exceeded stop-loss cap; active TWAP plans locked.',
          decisionHash: res.message.calldataPreview?.intentHash ?? deterministicHash(`BRK:${now}`),
          mode: 'LIVE-FEED ENGINE',
        },
        ...prev.slice(0, 29),
      ]);
    } else if (res.resetBreaker) {
      setHighWaterMark(portfolio.totalEquityUsd);
      setPlans((prev) => prev.map((p) => (p.status === 'BLOCKED' ? { ...p, status: 'ACTIVE' } : p)));
      setAuditLog((prev) => [
        {
          id: `rst-${now}`,
          timestamp: now,
          kind: 'BREAKER_RESET',
          summary: 'Owner reset Circuit Breaker · High-Water Mark re-anchored',
          detail: `Trading unlocked under ${res.nextPolicy.riskAppetite} policy rails.`,
          decisionHash: res.message.calldataPreview?.intentHash ?? deterministicHash(`RST:${now}`),
          mode: 'LIVE-FEED ENGINE',
        },
        ...prev.slice(0, 29),
      ]);
    } else if (res.newPlan) {
      setPlans((prev) => [res.newPlan!, ...prev.slice(0, 9)]);
      setAuditLog((prev) => [
        {
          id: `plan-${now}`,
          timestamp: now,
          kind: 'TWAP_CREATED',
          asset: res.newPlan!.asset,
          summary: `TWAP ${res.newPlan!.id}: ${res.newPlan!.side} $${res.newPlan!.totalNotionalUsd} ${res.newPlan!.asset}`,
          detail: `${res.newPlan!.slicesTotal} slices × $${res.newPlan!.sliceNotionalUsd} · saves ${res.newPlan!.bpsSaved} bps impact`,
          bpsSaved: res.newPlan!.bpsSaved,
          decisionHash: res.newPlan!.decisionHash,
          mode: 'LIVE-FEED ENGINE',
        },
        ...prev.slice(0, 29),
      ]);
      if (res.triggerImmediateSlice && !res.nextPolicy.paused && !res.nextPolicy.circuitBreakerTripped) {
        window.setTimeout(() => executeOneSlice(res.newPlan!, true), 450);
      }
    } else if (res.message.policyDiffs && res.message.policyDiffs.length > 0) {
      setAuditLog((prev) => [
        {
          id: `pol-${now}`,
          timestamp: now,
          kind: 'POLICY_UPDATED',
          summary: `Chat updated ${res.message.policyDiffs!.length} risk rail(s)`,
          detail: res.message.policyDiffs!.map((d) => `${d.field}: ${d.before}→${d.after}`).join(' | '),
          decisionHash: res.message.calldataPreview?.intentHash ?? deterministicHash(`POL:${now}`),
          mode: 'LIVE-FEED ENGINE',
        },
        ...prev.slice(0, 29),
      ]);
    }
  };

  const handleStageFromRow = (snap: MarketVenueSnapshot) => {
    const verdict = evaluateOpportunityAgainstPolicy(
      snap,
      policy,
      cooldownRemainingSec,
      tradesToday,
    );
    if (verdict.verdict === 'REFUSE') {
      const now = Date.now();
      setAuditLog((prev) => [
        {
          id: `ref-${now}`,
          timestamp: now,
          kind: 'OPPORTUNITY_REFUSED',
          asset: snap.asset,
          summary: `REFUSED ${snap.pair} (${verdict.reasonCode})`,
          detail: verdict.reasonText,
          netEdgeBps: snap.netEdgeBps,
          decisionHash: deterministicHash(`REFUSE:${snap.id}:${now}`),
          mode: 'LIVE-FEED ENGINE',
        },
        ...prev.slice(0, 29),
      ]);
      setMessages((prev) => [
        ...prev,
        {
          id: `ref-msg-${now}`,
          role: 'agent',
          timestamp: now,
          statusBadge: `REFUSED · ${verdict.reasonCode}`,
          text: `Logged refusal proof for ${snap.pair}: ${verdict.reasonText}`,
        },
      ]);
      return;
    }
    const side = snap.direction === 'SELL_ON_HSKSWAP' ? 'Sell' : 'Buy';
    handleChatSubmit(`${side} $${probeOrderUsd} of ${snap.asset} using TWAP`);
  };

  const handleToggleAsset = (sym: AssetSymbol) => {
    const enabled = policy.allowedAssets.includes(sym);
    handleChatSubmit(enabled ? `Disable ${sym}` : `Enable ${sym}`);
  };

  const handlePresetClick = (preset: RiskAppetite) => {
    handleChatSubmit(`Switch to ${preset.toLowerCase()} mode`);
  };

  const handleConnectWallet = async () => {
    setWalletErr(null);
    try {
      const conn = await connectHskTestnetWallet();
      setWallet(conn);
    } catch (e: unknown) {
      setWalletErr(e instanceof Error ? e.message : 'Wallet connection failed');
    }
  };

  // Equity Sparkline SVG points
  const sparkPath = useMemo(() => {
    const vals = equityHistory.length >= 2 ? equityHistory : [10000, 10000];
    const minV = Math.min(...vals) * 0.999;
    const maxV = Math.max(...vals) * 1.001;
    const range = Math.max(maxV - minV, 1);
    return vals
      .map((v, i) => {
        const x = (i / (vals.length - 1)) * 220;
        const y = 38 - ((v - minV) / range) * 32;
        return `${i === 0 ? 'M' : 'L'}${x.toFixed(1)},${y.toFixed(1)}`;
      })
      .join(' ');
  }, [equityHistory]);

  const activeWhskSnap = snapshots[0];
  const probeCalc = useMemo(
    () =>
      planLiquidityAwareTwap(
        probeOrderUsd,
        activeWhskSnap?.estimatedDepthUsd ?? 24_500,
        policy,
      ),
    [probeOrderUsd, activeWhskSnap, policy],
  );

  return (
    <div className="shell">
      {/* Top Telemetry Ribbon */}
      <header className="topbar">
        <div className="brand">
          <div className="brand-mark">
            <Zap size={20} />
          </div>
          <div>
            <h1>
              SpreadPilot HSK
              <span className="tag cyan">TRACK 1 · AI AGENT TRADING</span>
            </h1>
            <div className="brand-sub">
              Cross-Venue CEX↔HSKSwap Spread Arbitrage · Liquidity-Aware TWAP Splitter · On-Chain Risk Rails
            </div>
          </div>
        </div>

        <div className="telemetry-pills">
          <span className="pill live mono">
            <span className="dot" />
            HSK Mainnet {telemetry.mainnetBlock ? `#${telemetry.mainnetBlock.toLocaleString()}` : 'Syncing'}
          </span>
          <span className="pill cyan mono">
            HSK Testnet 133 {telemetry.testnetBlock ? `#${telemetry.testnetBlock.toLocaleString()}` : 'Syncing'}
          </span>
          <span className={`pill ${policy.circuitBreakerTripped ? 'danger' : policy.paused ? 'amber' : 'live'}`}>
            <span
              className={`dot ${
                policy.circuitBreakerTripped ? 'danger' : policy.paused ? 'amber' : ''
              }`}
            />
            {policy.circuitBreakerTripped
              ? 'BREAKER TRIPPED'
              : policy.paused
                ? 'AGENT PAUSED'
                : 'RAILS ARMED'}
          </span>
          <button
            className={`btn ${autoAgent ? 'primary' : ''}`}
            onClick={() => setAutoAgent((v) => !v)}
            type="button"
          >
            {autoAgent ? <Pause size={13} /> : <Play size={13} />}
            Auto-TWAP {autoAgent ? 'ON' : 'OFF'}
          </button>
          <button className="btn" onClick={() => void syncFeeds()} type="button">
            <RefreshCw size={13} className={syncing ? 'spin' : ''} />
            Sync ({telemetry.liveSourcesCount}/6 live)
          </button>
          <button className="btn" onClick={() => void handleConnectWallet()} type="button">
            <Wallet size={13} />
            {wallet ? shortHash(wallet.address) : 'Connect HSK 133'}
          </button>
        </div>
      </header>

      {walletErr && (
        <div className="pill danger" style={{ borderRadius: 8, justifyContent: 'space-between' }}>
          <span>{walletErr}</span>
          <button className="btn sm" onClick={() => setWalletErr(null)} type="button">
            Dismiss
          </button>
        </div>
      )}

      {/* KPI Strip */}
      <section className="kpi-strip">
        <div className="kpi-card">
          <div className="kpi-label">
            <span>Vault Equity (Mark)</span>
            <Activity size={13} />
          </div>
          <div className="kpi-value mono">${portfolio.totalEquityUsd.toLocaleString('en-US', { minimumFractionDigits: 2 })}</div>
          <div className="kpi-sub mono">
            Cash ${cashUsd.toFixed(0)} · Inv ${portfolio.inventoryUsd.toFixed(0)}
          </div>
        </div>

        <div className="kpi-card">
          <div className="kpi-label">
            <span>Realized + Unrealized PnL</span>
            <CheckCircle2 size={13} />
          </div>
          <div
            className={`kpi-value mono ${
              portfolio.realizedPnlUsd + portfolio.unrealizedPnlUsd >= 0 ? 'pos' : 'neg'
            }`}
          >
            {portfolio.realizedPnlUsd + portfolio.unrealizedPnlUsd >= 0 ? '+' : ''}$
            {(portfolio.realizedPnlUsd + portfolio.unrealizedPnlUsd).toFixed(2)}
          </div>
          <div className="kpi-sub mono">
            Realized +${portfolio.realizedPnlUsd.toFixed(2)} · Open{' '}
            {portfolio.unrealizedPnlUsd >= 0 ? '+' : ''}${portfolio.unrealizedPnlUsd.toFixed(2)}
          </div>
        </div>

        <div className="kpi-card">
          <div className="kpi-label">
            <span>Impact Saved by TWAP</span>
            <Layers size={13} />
          </div>
          <div className="kpi-value mono pos">-{cumulativeBpsSaved} bps</div>
          <div className="kpi-sub mono">vs naive single-shot thin-pool swaps</div>
        </div>

        <div className="kpi-card">
          <div className="kpi-label">
            <span>Drawdown vs Stop-Loss</span>
            {policy.circuitBreakerTripped ? <ShieldAlert size={13} /> : <ShieldCheck size={13} />}
          </div>
          <div className={`kpi-value mono ${portfolio.drawdownBps >= policy.stopLossDrawdownBps ? 'neg' : ''}`}>
            {(portfolio.drawdownBps / 100).toFixed(2)}% / {(policy.stopLossDrawdownBps / 100).toFixed(1)}%
          </div>
          <div className="kpi-sub mono">HWM ${highWaterMark.toFixed(0)} · Auto-lock on breach</div>
        </div>

        <div className="kpi-card">
          <div className="kpi-label">
            <span>Live Equity Curve</span>
            <span className="tag emerald">LIVE</span>
          </div>
          <svg viewBox="0 0 220 42" style={{ width: '100%', height: 38 }}>
            <path
              d={sparkPath}
              fill="none"
              stroke={policy.circuitBreakerTripped ? '#ef4444' : '#10b981'}
              strokeWidth="2.2"
              strokeLinecap="round"
            />
          </svg>
        </div>
      </section>

      {/* Main 3-Column Desk */}
      <main className="workspace">
        {/* LEFT: Live Spread Matrix + TWAP Liquidity Lens */}
        <div className="col">
          <section className="panel">
            <div className="panel-head">
              <div className="panel-title">
                <Activity size={14} color="#10b981" />
                Live CEX ↔ HSKSwap V3 Spread Matrix
              </div>
              <span className="mono" style={{ fontSize: 11, color: '#8b9bb0' }}>
                Probe Order: ${probeOrderUsd}
              </span>
            </div>
            <div className="table-wrap">
              <table className="matrix">
                <thead>
                  <tr>
                    <th>Pair / Pool</th>
                    <th>HSKSwap</th>
                    <th>CEX Ref</th>
                    <th>Gross</th>
                    <th>TWAP Plan</th>
                    <th>Net Edge</th>
                    <th>Action</th>
                  </tr>
                </thead>
                <tbody>
                  {snapshots.map((snap) => (
                    <tr key={snap.id}>
                      <td>
                        <div className="pair-main">{snap.pair}</div>
                        <div className="pair-sub">
                          <span>{snap.venueLabel}</span>
                          {snap.isOnChainLive ? (
                            <span className="tag emerald">ON-CHAIN 177</span>
                          ) : (
                            <span className="tag muted">CEX LIVE</span>
                          )}
                        </div>
                      </td>
                      <td className="mono">{fmtPrice(snap.hskSwapPrice)}</td>
                      <td className="mono">
                        <div>{fmtPrice(snap.cexMidPrice)}</div>
                        <div style={{ fontSize: 10, color: '#8b9bb0' }}>{snap.cexSource}</div>
                      </td>
                      <td className="mono">+{snap.grossSpreadBps} bps</td>
                      <td className="mono">
                        <div>
                          {snap.twapSlices}× ${snap.twapSliceUsd.toFixed(0)}
                        </div>
                        <div style={{ fontSize: 10, color: '#34d399' }}>
                          saves {snap.bpsSavedByTwap} bps
                        </div>
                      </td>
                      <td className="mono">
                        <span
                          className={`tag ${
                            snap.signal === 'EXECUTE_TWAP'
                              ? 'emerald'
                              : snap.signal === 'REFUSED'
                                ? 'red'
                                : 'amber'
                          }`}
                        >
                          {snap.netEdgeBps >= 0 ? '+' : ''}
                          {snap.netEdgeBps} bps
                        </span>
                      </td>
                      <td>
                        <button
                          className={`btn sm ${snap.signal === 'EXECUTE_TWAP' ? 'primary' : ''}`}
                          onClick={() => handleStageFromRow(snap)}
                          type="button"
                          title={snap.signalNote}
                        >
                          {snap.signal === 'EXECUTE_TWAP' ? 'Stage TWAP' : 'Test Gate'}
                        </button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </section>

          {/* Liquidity-Depth TWAP Splitter Simulator */}
          <section className="panel">
            <div className="panel-head">
              <div className="panel-title">
                <Layers size={14} color="#38bdf8" />
                HSKSwap Thin-Liquidity TWAP Impact Lens
              </div>
              <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                <span className="mono" style={{ fontSize: 11, color: '#8b9bb0' }}>
                  Order Size:
                </span>
                {[250, 800, 1500, 3000].map((sz) => (
                  <button
                    key={sz}
                    className={`btn sm ${probeOrderUsd === sz ? 'primary' : ''}`}
                    onClick={() => setProbeOrderUsd(sz)}
                    type="button"
                  >
                    ${sz}
                  </button>
                ))}
              </div>
            </div>
            <div className="panel-body">
              <div className="impact-row">
                <div className="impact-top">
                  <span>Naive Single-Shot Swap (${probeOrderUsd} into WHSK/USDT 0.05%)</span>
                  <span className="mono" style={{ color: '#f87171', fontWeight: 700 }}>
                    -{probeCalc.singleShotImpactBps} bps impact
                  </span>
                </div>
                <div className="bar-track">
                  <div
                    className="bar-fill-single"
                    style={{ width: `${Math.min(100, (probeCalc.singleShotImpactBps / 250) * 100)}%` }}
                  />
                </div>
              </div>

              <div className="impact-row">
                <div className="impact-top">
                  <span>
                    SpreadPilot Adaptive TWAP ({probeCalc.slices} × ${probeCalc.sliceNotionalUsd},{' '}
                    {policy.minSliceIntervalSec}s spacing)
                  </span>
                  <span className="mono" style={{ color: '#34d399', fontWeight: 700 }}>
                    -{probeCalc.twapImpactBps} bps (saves {probeCalc.bpsSaved} bps / ${probeCalc.usdSaved})
                  </span>
                </div>
                <div className="bar-track">
                  <div
                    className="bar-fill-twap"
                    style={{ width: `${Math.min(100, (probeCalc.twapImpactBps / 250) * 100)}%` }}
                  />
                </div>
              </div>

              {/* Active TWAP Queue */}
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginTop: 4 }}>
                <span style={{ fontWeight: 700, fontSize: 12 }}>Active &amp; Completed TWAP Orders ({plans.length})</span>
                <span className="mono" style={{ fontSize: 11, color: '#8b9bb0' }}>
                  Next slice cooldown: {cooldownRemainingSec}s
                </span>
              </div>
              {plans.length === 0 ? (
                <div className="audit-detail">
                  No TWAP plans staged yet. Click <b>Stage TWAP</b> above or instruct the copilot (e.g. "Buy $450 of WHSK using TWAP").
                </div>
              ) : (
                plans.slice(0, 4).map((p) => (
                  <div key={p.id} className="impact-row">
                    <div className="impact-top">
                      <span className="mono">
                        <b>{p.id}</b> · {p.side} ${p.totalNotionalUsd} {p.asset} ({p.slicesExecuted}/{p.slicesTotal} slices)
                      </span>
                      <span
                        className={`tag ${
                          p.status === 'COMPLETED'
                            ? 'emerald'
                            : p.status === 'BLOCKED'
                              ? 'red'
                              : 'cyan'
                        }`}
                      >
                        {p.status}
                      </span>
                    </div>
                    <div className="bar-track">
                      <div
                        className="bar-fill-twap"
                        style={{ width: `${(p.slicesExecuted / p.slicesTotal) * 100}%` }}
                      />
                    </div>
                  </div>
                ))
              )}
            </div>
          </section>
        </div>

        {/* CENTER: Conversational AI Trading Copilot */}
        <div className="col">
          <section className="panel chat-panel">
            <div className="panel-head">
              <div className="panel-title">
                <Bot size={15} color="#10b981" />
                Conversational AI Policy &amp; Execution Copilot
              </div>
              <span className="tag emerald">DETERMINISTIC + ON-CHAIN ABI</span>
            </div>

            <div className="prompt-chips">
              {QUICK_PROMPTS.map((q) => (
                <button
                  key={q.label}
                  className={`chip ${q.warn ? 'warn' : ''}`}
                  onClick={() => handleChatSubmit(q.text)}
                  type="button"
                >
                  {q.label}
                </button>
              ))}
            </div>

            <div className="chat-stream">
              {messages.map((m) => (
                <div key={m.id} className={`msg ${m.role}`}>
                  <div className="msg-meta">
                    <span>{m.role === 'user' ? 'Portfolio Owner' : 'SpreadPilot Agent'}</span>
                    {m.statusBadge && (
                      <span
                        className={`tag ${
                          m.statusBadge.includes('TRIPPED') || m.statusBadge.includes('REFUSED')
                            ? 'red'
                            : 'emerald'
                        }`}
                      >
                        {m.statusBadge}
                      </span>
                    )}
                  </div>
                  <div>{m.text}</div>
                  {m.policyDiffs && m.policyDiffs.length > 0 && (
                    <div className="diff-grid">
                      {m.policyDiffs.map((d) => (
                        <span key={d.field} className="diff-pill mono">
                          {d.field}: {d.before} → {d.after}
                        </span>
                      ))}
                    </div>
                  )}
                  {m.planSummary && (
                    <div className="diff-grid">
                      <span className="diff-pill mono">
                        {m.planSummary.side} ${m.planSummary.totalUsd} {m.planSummary.asset}
                      </span>
                      <span className="diff-pill mono">
                        {m.planSummary.slices} × ${m.planSummary.sliceUsd}
                      </span>
                      <span className="diff-pill mono">
                        Impact {m.planSummary.singleImpactBps}→{m.planSummary.twapImpactBps} bps (-
                        {m.planSummary.bpsSaved} bps)
                      </span>
                    </div>
                  )}
                  {m.calldataPreview && (
                    <div className="calldata-box mono">
                      <div>
                        <b>target:</b>{' '}
                        {m.calldataPreview.target.startsWith('0x') ? (
                          <a
                            className="ext-link"
                            href={getExplorerAddressUrl('testnet', m.calldataPreview.target)}
                            target="_blank"
                            rel="noreferrer"
                          >
                            {shortHash(m.calldataPreview.target)} <ExternalLink size={10} />
                          </a>
                        ) : (
                          m.calldataPreview.target
                        )}
                      </div>
                      <div>
                        <b>tx:</b> {m.calldataPreview.fnName}
                      </div>
                      <div>
                        <b>args:</b> {m.calldataPreview.argsSummary}
                      </div>
                      <div>
                        <b>intentHash:</b> {shortHash(m.calldataPreview.intentHash)}
                      </div>
                    </div>
                  )}
                </div>
              ))}
              <div ref={chatEndRef} />
            </div>

            <form
              className="chat-form"
              onSubmit={(e) => {
                e.preventDefault();
                handleChatSubmit(chatInput);
              }}
            >
              <input
                className="chat-input"
                value={chatInput}
                onChange={(e) => setChatInput(e.target.value)}
                placeholder='e.g. "Conservative mode, cap slice $150, stop-loss 3%, buy $400 WHSK TWAP"'
              />
              <button className="btn primary" type="submit">
                <Send size={13} />
                Send
              </button>
            </form>
          </section>
        </div>

        {/* RIGHT: Risk Rails, Positions, Audit Log & HSK Testnet Receipts */}
        <div className="col">
          <section className="panel">
            <div className="panel-head">
              <div className="panel-title">
                <Sliders size={14} color="#f59e0b" />
                Enforced On-Chain Risk Rails
              </div>
              <div style={{ display: 'flex', gap: 4 }}>
                {(['CONSERVATIVE', 'BALANCED', 'AGGRESSIVE'] as RiskAppetite[]).map((mode) => (
                  <button
                    key={mode}
                    className={`btn sm ${policy.riskAppetite === mode ? 'primary' : ''}`}
                    onClick={() => handlePresetClick(mode)}
                    type="button"
                  >
                    {mode.slice(0, 4)}
                  </button>
                ))}
              </div>
            </div>
            <div className="panel-body">
              <div className="rail-grid">
                <div className="rail-box">
                  <div className="rail-k">Max Slice / Order</div>
                  <div className="rail-v mono">
                    ${policy.maxSliceNotionalUsd} / ${policy.maxOrderNotionalUsd}
                  </div>
                </div>
                <div className="rail-box">
                  <div className="rail-k">Cooldown / Daily Cap</div>
                  <div className="rail-v mono">
                    {policy.minSliceIntervalSec}s · {tradesToday}/{policy.maxDailyTrades}
                  </div>
                </div>
                <div className="rail-box">
                  <div className="rail-k">Min Net Edge / Max Slip</div>
                  <div className="rail-v mono">
                    +{policy.minNetEdgeBps} / {policy.maxSlippageBps} bps
                  </div>
                </div>
                <div className="rail-box">
                  <div className="rail-k">Stop-Loss / Daily Loss</div>
                  <div className="rail-v mono">
                    {(policy.stopLossDrawdownBps / 100).toFixed(1)}% · ${policy.dailyLossLimitUsd}
                  </div>
                </div>
              </div>

              <div>
                <div className="rail-k" style={{ marginBottom: 5 }}>
                  Target Asset Allowlist (click or command in chat)
                </div>
                <div className="asset-chips">
                  {(['WHSK', 'WETH', 'WBTC', 'USDC'] as AssetSymbol[]).map((sym) => {
                    const on = policy.allowedAssets.includes(sym);
                    return (
                      <button
                        key={sym}
                        className={`asset-toggle mono ${on ? 'on' : ''}`}
                        onClick={() => handleToggleAsset(sym)}
                        type="button"
                      >
                        {on ? '✓ ' : '✕ '}
                        {sym}
                      </button>
                    );
                  })}
                </div>
              </div>

              {policy.circuitBreakerTripped && (
                <div className="impact-row" style={{ borderColor: 'rgba(239,68,68,0.6)' }}>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 6, color: '#fca5a5', fontWeight: 700 }}>
                    <AlertTriangle size={14} />
                    Stop-Loss Circuit Breaker Active
                  </div>
                  <div className="audit-detail">{policy.breakerReason}</div>
                  <button
                    className="btn danger sm"
                    onClick={() => handleChatSubmit('Reset circuit breaker')}
                    type="button"
                  >
                    Owner Reset Breaker
                  </button>
                </div>
              )}
            </div>
          </section>

          {/* Live Positions Ledger */}
          <section className="panel">
            <div className="panel-head">
              <div className="panel-title">Open Positions &amp; Live PnL</div>
              <span className="mono" style={{ fontSize: 11, color: '#8b9bb0' }}>
                USDT Cash ${cashUsd.toFixed(2)}
              </span>
            </div>
            <div className="table-wrap">
              <table className="matrix">
                <thead>
                  <tr>
                    <th>Asset</th>
                    <th>Qty</th>
                    <th>Avg Entry</th>
                    <th>Mark</th>
                    <th>PnL</th>
                  </tr>
                </thead>
                <tbody>
                  {(Object.keys(positions) as AssetSymbol[]).map((sym) => {
                    const pos = positions[sym];
                    const mark = markPrices[sym] || pos.avgEntryUsd;
                    const unreal = pos.qty > 0 ? (mark - pos.avgEntryUsd) * pos.qty : 0;
                    const total = pos.realizedPnlUsd + unreal;
                    return (
                      <tr key={sym}>
                        <td className="mono" style={{ fontWeight: 700 }}>
                          {sym}
                        </td>
                        <td className="mono">{pos.qty >= 100 ? pos.qty.toFixed(0) : pos.qty.toFixed(4)}</td>
                        <td className="mono">{fmtPrice(pos.avgEntryUsd)}</td>
                        <td className="mono">{fmtPrice(mark)}</td>
                        <td className="mono" style={{ color: total >= 0 ? '#34d399' : '#f87171' }}>
                          {total >= 0 ? '+' : ''}${total.toFixed(2)}
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          </section>

          {/* Verifiable Audit Trail + HSK Chain Deployment Receipts */}
          <section className="panel">
            <div className="panel-head">
              <div className="panel-title">On-Chain Execution &amp; Refusal Audit Trail</div>
              <span className="tag cyan">HSK 133 / 177</span>
            </div>
            <div className="panel-body">
              <div className="audit-list">
                {getVerifiedTestnetTxs().map((tx) => (
                  <div key={tx.txHash} className="audit-item" style={{ borderColor: 'rgba(56,189,248,0.4)' }}>
                    <div className="audit-head">
                      <span>{tx.label}</span>
                      <a
                        className="ext-link mono"
                        href={tx.explorerUrl}
                        target="_blank"
                        rel="noreferrer"
                      >
                        {shortHash(tx.txHash)} <ExternalLink size={11} />
                      </a>
                    </div>
                    <div className="audit-detail">{tx.summary}</div>
                  </div>
                ))}

                {auditLog.slice(0, 8).map((entry) => (
                  <div key={entry.id} className="audit-item">
                    <div className="audit-head">
                      <span>{entry.summary}</span>
                      <span
                        className={`tag ${
                          entry.kind === 'SLICE_EXECUTED'
                            ? 'emerald'
                            : entry.kind === 'BREAKER_TRIPPED' || entry.kind === 'OPPORTUNITY_REFUSED'
                              ? 'red'
                              : 'cyan'
                        }`}
                      >
                        {entry.kind.replace(/_/g, ' ')}
                      </span>
                    </div>
                    <div className="audit-detail">{entry.detail}</div>
                    <div className="audit-detail mono">
                      hash {shortHash(entry.decisionHash)}
                    </div>
                  </div>
                ))}
              </div>

              <div className="audit-detail mono" style={{ borderTop: '1px solid #1d2b3b', paddingTop: 8 }}>
                Live Pools:{' '}
                <a
                  className="ext-link"
                  href={getExplorerAddressUrl('mainnet', HSK_MAINNET.pools.whskUsdt500.address)}
                  target="_blank"
                  rel="noreferrer"
                >
                  WHSK/USDT 0.05% <ExternalLink size={10} />
                </a>{' '}
                ·{' '}
                <a
                  className="ext-link"
                  href={getExplorerAddressUrl('mainnet', HSK_MAINNET.pools.whskUsdt3000.address)}
                  target="_blank"
                  rel="noreferrer"
                >
                  WHSK/USDT 0.30% <ExternalLink size={10} />
                </a>
                {isTestnetDeployed() ? (
                  getTestnetContractLinks().map((item) => (
                    <span key={item.label}>
                      {' · '}
                      <a
                        className="ext-link"
                        href={item.explorerUrl}
                        target="_blank"
                        rel="noreferrer"
                      >
                        {item.label} <ExternalLink size={10} />
                      </a>
                    </span>
                  ))
                ) : (
                  <span> · HSK 133: pending DeployHSKTestnet.s.sol</span>
                )}
              </div>
            </div>
          </section>
        </div>
      </main>
    </div>
  );
}

export type RiskAppetite = 'CONSERVATIVE' | 'BALANCED' | 'AGGRESSIVE';

export type AssetSymbol = 'WHSK' | 'WETH' | 'WBTC' | 'USDC';

export interface ExecutionPolicy {
  riskAppetite: RiskAppetite;
  maxSliceNotionalUsd: number;
  maxOrderNotionalUsd: number;
  minSliceIntervalSec: number;
  minNetEdgeBps: number;
  maxSlippageBps: number;
  stopLossDrawdownBps: number;
  dailyLossLimitUsd: number;
  maxDailyTrades: number;
  allowedAssets: AssetSymbol[];
  paused: boolean;
  circuitBreakerTripped: boolean;
  breakerReason: string | null;
}

export interface MarketVenueSnapshot {
  id: string;
  pair: string;
  asset: AssetSymbol;
  venueLabel: string;
  poolAddress?: string;
  poolFeeBps: number;
  hskSwapPrice: number;
  cexMidPrice: number;
  cexBid: number;
  cexAsk: number;
  cexSource: string;
  onChainLiquidityRaw: string;
  estimatedDepthUsd: number;
  grossSpreadBps: number;
  direction: 'BUY_ON_HSKSWAP' | 'SELL_ON_HSKSWAP' | 'INTER_POOL_ARB';
  singleShotImpactBps: number;
  twapSlices: number;
  twapSliceUsd: number;
  twapImpactBps: number;
  bpsSavedByTwap: number;
  netEdgeBps: number;
  signal: 'EXECUTE_TWAP' | 'MONITOR' | 'REFUSED';
  signalNote: string;
  isOnChainLive: boolean;
  isCexLive: boolean;
  updatedAt: number;
}

export interface TwapPlan {
  id: string;
  asset: AssetSymbol;
  pair: string;
  side: 'BUY' | 'SELL';
  totalNotionalUsd: number;
  sliceNotionalUsd: number;
  slicesTotal: number;
  slicesExecuted: number;
  minNetEdgeBps: number;
  maxSlippageBps: number;
  singleShotImpactBps: number;
  twapImpactBps: number;
  bpsSaved: number;
  avgFillPrice: number;
  status: 'ACTIVE' | 'COMPLETED' | 'CANCELLED' | 'BLOCKED';
  createdAt: number;
  lastSliceAt: number;
  decisionHash: string;
  txHash?: string;
}

export interface Position {
  asset: AssetSymbol;
  qty: number;
  avgEntryUsd: number;
  realizedPnlUsd: number;
}

export interface AuditEntry {
  id: string;
  timestamp: number;
  kind:
    | 'SLICE_EXECUTED'
    | 'OPPORTUNITY_REFUSED'
    | 'POLICY_UPDATED'
    | 'TWAP_CREATED'
    | 'BREAKER_TRIPPED'
    | 'BREAKER_RESET';
  asset?: AssetSymbol;
  summary: string;
  detail: string;
  netEdgeBps?: number;
  bpsSaved?: number;
  decisionHash: string;
  txHash?: string;
  mode: 'ON-CHAIN HSK 133' | 'LIVE-FEED ENGINE';
}

export interface PolicyDiff {
  field: string;
  before: string;
  after: string;
}

export interface ChatMessage {
  id: string;
  role: 'user' | 'agent';
  timestamp: number;
  text: string;
  statusBadge?: string;
  policyDiffs?: PolicyDiff[];
  calldataPreview?: {
    target: string;
    fnName: string;
    argsSummary: string;
    intentHash: string;
  };
  planSummary?: {
    asset: AssetSymbol;
    side: 'BUY' | 'SELL';
    totalUsd: number;
    slices: number;
    sliceUsd: number;
    singleImpactBps: number;
    twapImpactBps: number;
    bpsSaved: number;
  };
}

export interface NetworkTelemetry {
  mainnetBlock: number | null;
  testnetBlock: number | null;
  lastSyncAt: number | null;
  liveSourcesCount: number;
  errorNote: string | null;
}

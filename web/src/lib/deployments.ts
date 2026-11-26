export const HSK_MAINNET = {
  chainId: 177,
  chainIdHex: '0xb1',
  name: 'HSK Chain Mainnet',
  rpcUrl: 'https://mainnet.hsk.xyz',
  explorer: 'https://hsk.blockscout.com',
  hskSwapRouter: '0x1f3858C46F8F6fE76260b8208995D228C5cddc64',
  hskSwapFactory: '0xD136e36610f35E0Cc3cAd40de858c151f2AA65D4',
  tokens: {
    WHSK: { address: '0xB210D2120d57b758EE163cFfb43e73728c471Cf1', decimals: 18 },
    USDT: { address: '0xf1b50ed67a9e2cc94ad3c477779e2d4cbfff9029', decimals: 6 },
    USDC: { address: '0x054ed45810DbBAb8B27668922D110669c9D88D0a', decimals: 6 },
    WETH: { address: '0xefd4bC9afD210517803f293ABABd701CaeeCdfd0', decimals: 18 },
    WBTC: { address: '0x6119ca49a79f5825c8b345f8d7ac36b272565b14', decimals: 8 },
  },
  pools: {
    whskUsdt500: {
      address: '0xEB33d6666dd2359cB1BF6Ea6D72286Cc1b4a778A',
      feeBps: 5,
      decimals0: 18, // WHSK
      decimals1: 6, // USDT
    },
    whskUsdt3000: {
      address: '0x0767F7b1af495D245EA00219cFB8B2Ed6EafAe62',
      feeBps: 30,
      decimals0: 18, // WHSK
      decimals1: 6, // USDT
    },
  },
} as const;

export const HSK_TESTNET = {
  chainId: 133,
  chainIdHex: '0x85',
  name: 'HSKChain Testnet',
  rpcUrl: 'https://testnet.hsk.xyz',
  explorer: 'https://testnet-explorer.hskchain.net',
  hskSwapRouter02: '0x46cBccE3c74E95d1761435d52B0b9Abc9e2FEAC0',
  hskSwapFactory: '0x2dC2c21D1049F786C535bF9d45F999dB5474f3A0',
} as const;

export const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000' as const;

export interface TestnetDeploymentRecord {
  status: 'PENDING_BROADCAST' | 'DEPLOYED_LIVE';
  chainId: number;
  deployer: string;
  vaultAddress: string;
  lensAddress: string;
  adapterAddress: string;
  poolAddress?: string;
  tokens: {
    tWHSK: string;
    tUSDT: string;
    tWETH: string;
    tWBTC: string;
  };
  verifiedTxs: Array<{
    label: string;
    txHash: string;
    summary: string;
  }>;
}

export interface ExplorerContractLink {
  label: string;
  address: string;
  explorerUrl: string;
}

export interface ExplorerTxLink {
  label: string;
  txHash: string;
  summary: string;
  explorerUrl: string;
}

// Live verified deployment on HSKChain Testnet (Chain ID 133) via DeployHSKTestnet.s.sol + RunDemoScenario.s.sol
export const TESTNET_DEPLOYMENT: TestnetDeploymentRecord = {
  status: 'DEPLOYED_LIVE',
  chainId: 133,
  deployer: '0xEcA8Ac4BE10da6977f19Dc7D85Bb5951914B97B5',
  vaultAddress: '0xA681677D5c9142751682D384a92eA9c125782A51',
  lensAddress: '0xfF1E8e50C8895897C00a0c801E73abE2F1337edA',
  adapterAddress: '0x48eba200ACC1C45bC83eF9a5c1445d690470453E',
  poolAddress: '0x6Ad9eF968B424FFEe9ca062Ff88200F6Fb23f1Ee',
  tokens: {
    tWHSK: '0xF7Cbd0ca6c7A7360C9792fE3CE94656a4A01070B',
    tUSDT: '0xcA6cbb96309777FD4D38fad4Ff83315c80401124',
    tWETH: '0xAa91700f39D538E1C36e0d46d489d0D016a7Ee1B',
    tWBTC: '0xc14fe8D1781574a8630e4Fc2a381854BE4d0621e',
  },
  verifiedTxs: [
    {
      label: 'HSK 133 · Deposit 3,000 tUSDT',
      txHash: '0xa3539b28797f95a9e07e314f520f95422d66a8668470a6316830dd1abb5d6712',
      summary: 'Non-custodial owner deposit into SpreadPilotVault (HWM anchored at $3,000)',
    },
    {
      label: 'HSK 133 · Chat Policy Update',
      txHash: '0x809f674ade515f2eee5e2ad8433b6e34a5e02d6e50543a65ae2b33e3e97d305f',
      summary: 'updatePolicy(BALANCED, maxSlice=$1,000, minEdge=15bps, stopLoss=5%, chatIntentHash)',
    },
    {
      label: 'HSK 133 · Create 3-Slice TWAP',
      txHash: '0x3cdef6840834d69e28314263e82e734d8ccc2016c0cef1a42bf67e5dcb5489c4',
      summary: 'createTwapPlan(3,000 tUSDT -> tWHSK, 3 slices × 1,000 tUSDT · lens saves 686 bps)',
    },
    {
      label: 'HSK 133 · Execute Slice #1 (+28 bps)',
      txHash: '0x5c9fb51cfcbb175d9c112b181e77935d164dd58a790374ca414765e0b4796ea4',
      summary: '1,000 tUSDT -> 2,003.9975 tWHSK via ISwapRouter02 · +686 bps impact saved',
    },
    {
      label: 'HSK 133 · Execute Slice #2 (+22 bps)',
      txHash: '0xf698fcc3283626e787fed949830c36d96ace8568e150f569abebe07676f2a28b',
      summary: '1,000 tUSDT -> 2,003.9975 tWHSK · realized edge +3.9975 tUSDT (1,372 bps saved)',
    },
    {
      label: 'HSK 133 · Refusal Proof (+6 bps < 15)',
      txHash: '0xc3faa7897d6e320cea033189ce44f0ce469a15320cbd021746288ba1deeb161a',
      summary: 'logRefusedOpportunity(REFUSAL_SPREAD_BELOW_MIN) without moving vault funds',
    },
    {
      label: 'HSK 133 · Stop-Loss Breaker Tripped',
      txHash: '0x130ad06a691a9583b3ff8a8e35cfa0eb1ba20702f1923746862b2cb007182e5d',
      summary: 'reportMarkToMarketAndCheckStopLoss(-6.67% > 5% rail) -> circuitBreakerTripped=true',
    },
    {
      label: 'HSK 133 · Slice #3 Blocked Proof',
      txHash: '0xe7dcf09d43c033d336886902492167c8ae4e746aa17a1d14900dff0216e9a26d',
      summary: 'logRefusedOpportunity(REFUSAL_CIRCUIT_BREAKER) · staticcall verified Slice #3 reverts',
    },
  ],
};

export function isZeroAddress(address?: string): boolean {
  return !address || address.toLowerCase() === ZERO_ADDRESS;
}

export function isTestnetDeployed(dep: TestnetDeploymentRecord = TESTNET_DEPLOYMENT): boolean {
  return dep.status === 'DEPLOYED_LIVE' && !isZeroAddress(dep.vaultAddress);
}

export function getExplorerAddressUrl(chain: 'mainnet' | 'testnet', address: string): string {
  const base = chain === 'mainnet' ? HSK_MAINNET.explorer : HSK_TESTNET.explorer;
  return `${base}/address/${address}`;
}

export function getExplorerTxUrl(chain: 'mainnet' | 'testnet', txHash: string): string {
  const base = chain === 'mainnet' ? HSK_MAINNET.explorer : HSK_TESTNET.explorer;
  return `${base}/tx/${txHash}`;
}

export function getTestnetContractLinks(
  dep: TestnetDeploymentRecord = TESTNET_DEPLOYMENT,
): ExplorerContractLink[] {
  if (!isTestnetDeployed(dep)) return [];
  const candidates: Array<{ label: string; address?: string }> = [
    { label: 'Vault (133)', address: dep.vaultAddress },
    { label: 'Lens (133)', address: dep.lensAddress },
    { label: 'Adapter (133)', address: dep.adapterAddress },
    { label: 'V3 Pool (133)', address: dep.poolAddress },
  ];
  return candidates
    .filter((c): c is { label: string; address: string } => !isZeroAddress(c.address))
    .map((c) => ({
      label: c.label,
      address: c.address,
      explorerUrl: getExplorerAddressUrl('testnet', c.address),
    }));
}

export function getVerifiedTestnetTxs(
  dep: TestnetDeploymentRecord = TESTNET_DEPLOYMENT,
): ExplorerTxLink[] {
  return dep.verifiedTxs
    .filter((tx) => Boolean(tx.txHash && tx.txHash.startsWith('0x')))
    .map((tx) => ({
      ...tx,
      explorerUrl: getExplorerTxUrl('testnet', tx.txHash),
    }));
}

export function formatDeploymentTarget(
  role: 'vault' | 'lens' | 'adapter',
  dep: TestnetDeploymentRecord = TESTNET_DEPLOYMENT,
): string {
  const map = {
    vault: { addr: dep.vaultAddress, name: 'SpreadPilotVault' },
    lens: { addr: dep.lensAddress, name: 'HSKSwapLiquidityLens' },
    adapter: { addr: dep.adapterAddress, name: 'TestnetHSKSwapAdapter' },
  } as const;
  const entry = map[role];
  if (isTestnetDeployed(dep) && !isZeroAddress(entry.addr)) {
    return entry.addr;
  }
  return `${entry.name} (HSK 133 · pending broadcast)`;
}

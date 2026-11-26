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
  explorer: 'https://testnet-explorer.hsk.xyz',
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

// Updated automatically once DeployHSKTestnet.s.sol + RunDemoScenario.s.sol broadcast on Chain ID 133
export const TESTNET_DEPLOYMENT: TestnetDeploymentRecord = {
  status: 'PENDING_BROADCAST',
  chainId: 133,
  deployer: '0x0Cf943E4043b47D2ccba0ca94a2d45989a3fF260',
  vaultAddress: ZERO_ADDRESS,
  lensAddress: ZERO_ADDRESS,
  adapterAddress: ZERO_ADDRESS,
  poolAddress: ZERO_ADDRESS,
  tokens: {
    tWHSK: ZERO_ADDRESS,
    tUSDT: ZERO_ADDRESS,
    tWETH: ZERO_ADDRESS,
    tWBTC: ZERO_ADDRESS,
  },
  verifiedTxs: [],
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

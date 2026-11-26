import { HSK_TESTNET } from './deployments';

interface Eip1193Provider {
  request: (args: { method: string; params?: unknown[] }) => Promise<unknown>;
}

declare global {
  interface Window {
    ethereum?: Eip1193Provider;
  }
}

export interface WalletConnection {
  address: string;
  chainId: number;
  isHskTestnet: boolean;
}

export async function connectHskTestnetWallet(): Promise<WalletConnection> {
  if (!window.ethereum) {
    throw new Error('No EIP-1193 browser wallet detected (MetaMask / Rabby / OKX Wallet).');
  }
  const accounts = (await window.ethereum.request({
    method: 'eth_requestAccounts',
  })) as string[];
  const address = accounts?.[0];
  if (!address) throw new Error('Wallet connection rejected.');

  let chainHex = (await window.ethereum.request({ method: 'eth_chainId' })) as string;
  let chainId = parseInt(chainHex, 16);

  if (chainId !== HSK_TESTNET.chainId) {
    try {
      await window.ethereum.request({
        method: 'wallet_switchEthereumChain',
        params: [{ chainId: HSK_TESTNET.chainIdHex }],
      });
    } catch (err: unknown) {
      const code = (err as { code?: number })?.code;
      if (code === 4902) {
        await window.ethereum.request({
          method: 'wallet_addEthereumChain',
          params: [
            {
              chainId: HSK_TESTNET.chainIdHex,
              chainName: HSK_TESTNET.name,
              nativeCurrency: { name: 'HSK', symbol: 'HSK', decimals: 18 },
              rpcUrls: [HSK_TESTNET.rpcUrl],
              blockExplorerUrls: [HSK_TESTNET.explorer],
            },
          ],
        });
      }
    }
    chainHex = (await window.ethereum.request({ method: 'eth_chainId' })) as string;
    chainId = parseInt(chainHex, 16);
  }

  return {
    address,
    chainId,
    isHskTestnet: chainId === HSK_TESTNET.chainId,
  };
}

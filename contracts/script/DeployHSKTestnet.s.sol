// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {HSKSwapLiquidityLens} from "../src/HSKSwapLiquidityLens.sol";
import {SpreadPilotVault} from "../src/SpreadPilotVault.sol";
import {SpreadPilotTypes} from "../src/SpreadPilotTypes.sol";
import {TestnetMintableERC20} from "../src/TestnetMintableERC20.sol";
import {TestnetHSKSwapAdapter, TestnetV3Pool} from "../src/TestnetHSKSwapAdapter.sol";

/// @title DeployHSKTestnet
/// @notice One-command deployment script for SpreadPilot HSK on HSK Chain Testnet (Chain ID 133).
/// @dev Reads PRIVATE_KEY at runtime via vm.envUint("PRIVATE_KEY"). Never hardcode or print keys.
contract DeployHSKTestnet is Script {
    // Verified official HSK Chain Testnet SwapRouter02
    address public constant HSK_TESTNET_SWAP_ROUTER_02 = 0x46cBccE3c74E95d1761435d52B0b9Abc9e2FEAC0;

    // sqrtPriceX96 for token0=tWHSK (18 dec), token1=tUSDT (6 dec) at $0.50/tWHSK:
    // sqrt(0.5e6 / 1e18) * 2^96 = 56022770974786139918731
    uint160 public constant INITIAL_WHSK_USDT_SQRT_PRICE_X96 = 56_022_770_974_786_139_918_731;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address agent = vm.envOr("AGENT_ADDRESS", deployer);

        vm.startBroadcast(deployerKey);

        // 1. Deploy testnet tokens with mainnet-matching decimals
        TestnetMintableERC20 tWHSK = new TestnetMintableERC20("Testnet Wrapped HSK", "tWHSK", 18);
        TestnetMintableERC20 tUSDT = new TestnetMintableERC20("Testnet Tether USD", "tUSDT", 6);
        TestnetMintableERC20 tWETH = new TestnetMintableERC20("Testnet Wrapped ETH", "tWETH", 18);
        TestnetMintableERC20 tWBTC = new TestnetMintableERC20("Testnet Wrapped BTC", "tWBTC", 8);

        // 2. Deploy zero-gas V3 liquidity & TWAP slice lens
        HSKSwapLiquidityLens lens = new HSKSwapLiquidityLens();

        // 3. Deploy ISwapRouter02-compatible testnet AMM adapter + V3 pool mirror
        TestnetHSKSwapAdapter adapter = new TestnetHSKSwapAdapter();
        TestnetV3Pool whskUsdtPool = new TestnetV3Pool(
            address(tWHSK),
            address(tUSDT),
            500, // 0.05% fee tier matching mainnet WHSK/USDT pool
            INITIAL_WHSK_USDT_SQRT_PRICE_X96,
            -283_268,
            25_000e6 // thin active depth so TWAP slicing visibly saves impact
        );

        // Fund adapter reserves for live testnet swaps
        tWHSK.mint(address(adapter), 2_000_000e18);
        tUSDT.mint(address(adapter), 1_000_000e6);
        tWETH.mint(address(adapter), 500e18);
        tWBTC.mint(address(adapter), 25e8);

        // Configure realistic directional rates & spread bonuses
        // tUSDT (6 dec) -> tWHSK (18 dec) at $0.50 (1 tUSDT = 2 tWHSK => rate1e18 = 2e30)
        // Virtual depth = 500,000 tUSDT (20 bps impact on 1,000 tUSDT slice vs 60 bps single-shot on 3,000 tUSDT)
        // +45 bps spread bonus => 1,000 tUSDT slice nets +20 bps profit while single-shot 3,000 tUSDT loses!
        adapter.setPairConfig(address(tUSDT), address(tWHSK), 2e30, 500_000e6, 45);
        // tWHSK (18 dec) -> tUSDT (6 dec) at $0.50 (1 tWHSK = 0.5 tUSDT => rate1e18 = 5e5)
        adapter.setPairConfig(address(tWHSK), address(tUSDT), 5e5, 1_000_000e18, 45);
        // tUSDT (6 dec) <-> tWETH (18 dec) at $3,200
        adapter.setPairConfig(address(tUSDT), address(tWETH), 312_500_000_000_000_000_000_000_000, 1_000_000e6, 30);
        adapter.setPairConfig(address(tWETH), address(tUSDT), 3_200e6, 500e18, 30);
        // tUSDT (6 dec) <-> tWBTC (8 dec) at $95,000
        adapter.setPairConfig(address(tUSDT), address(tWBTC), 1_052_631_578_947_368, 1_500_000e6, 25);
        adapter.setPairConfig(address(tWBTC), address(tUSDT), 95_000e16, 20e8, 25);

        // 4. Deploy non-custodial user-owned SpreadPilotVault
        SpreadPilotVault vault = new SpreadPilotVault(deployer, address(tUSDT));
        vault.setAllowedToken(address(tWHSK), true);
        vault.setAllowedToken(address(tWETH), true);
        vault.setAllowedToken(address(tWBTC), true);
        vault.setAllowedRouter(address(adapter), true);
        vault.setAllowedRouter(HSK_TESTNET_SWAP_ROUTER_02, true);
        vault.setAuthorizedAgent(agent, uint64(block.timestamp + 30 days));
        vault.applyRiskPreset(SpreadPilotTypes.RiskAppetite.BALANCED);

        // 5. Mint initial demo inventory to deployer
        tUSDT.mint(deployer, 10_000e6);
        tWHSK.mint(deployer, 20_000e18);

        vm.stopBroadcast();

        console2.log("=== SpreadPilot HSK Testnet Deployment (Chain ID 133) ===");
        console2.log("Deployer:            ", deployer);
        console2.log("Authorized Agent:    ", agent);
        console2.log("tWHSK:               ", address(tWHSK));
        console2.log("tUSDT:               ", address(tUSDT));
        console2.log("tWETH:               ", address(tWETH));
        console2.log("tWBTC:               ", address(tWBTC));
        console2.log("HSKSwapLiquidityLens:", address(lens));
        console2.log("TestnetV3Pool:       ", address(whskUsdtPool));
        console2.log("TestnetHSKSwapAdapter:", address(adapter));
        console2.log("SpreadPilotVault:    ", address(vault));
    }
}

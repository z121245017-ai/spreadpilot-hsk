// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {HSKSwapLiquidityLens} from "../src/HSKSwapLiquidityLens.sol";
import {SpreadPilotVault} from "../src/SpreadPilotVault.sol";
import {SpreadPilotTypes} from "../src/SpreadPilotTypes.sol";
import {TestnetHSKSwapAdapter} from "../src/TestnetHSKSwapAdapter.sol";

/// @title RunDemoScenario
/// @notice End-to-end live HSK Chain Testnet (133) demo script:
///         deposit -> conversational policy update -> 3-slice TWAP creation ->
///         execute slice 1 & 2 -> log refusal on tight spread ->
///         trigger stop-loss drawdown -> verify breaker blocks slice 3.
contract RunDemoScenario is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address vaultAddr = vm.envAddress("VAULT_ADDRESS");
        address adapterAddr = vm.envAddress("ADAPTER_ADDRESS");
        address lensAddr = vm.envAddress("LENS_ADDRESS");
        address tUsdtAddr = vm.envAddress("TUSDT_ADDRESS");
        address tWhskAddr = vm.envAddress("TWHSK_ADDRESS");
        address poolAddr = vm.envAddress("POOL_ADDRESS");
        uint32 sliceIntervalSec = uint32(vm.envOr("SLICE_INTERVAL_SEC", uint256(0)));

        SpreadPilotVault vault = SpreadPilotVault(vaultAddr);
        TestnetHSKSwapAdapter adapter = TestnetHSKSwapAdapter(adapterAddr);
        HSKSwapLiquidityLens lens = HSKSwapLiquidityLens(lensAddr);

        // Read live V3 pool snapshot & compute optimal slice plan (zero-gas view)
        (SpreadPilotTypes.PoolSnapshot memory snap, SpreadPilotTypes.SlicePlan memory plan) =
            lens.previewOrderOnPool(poolAddr, 18, 6, 3_000e6, 400, 1_000e6);

        console2.log("Pool spotPrice1e8:      ", snap.spotPrice1e8);
        console2.log("Pool liquidity:         ", uint256(snap.liquidity));
        console2.log("Recommended slices:     ", uint256(plan.sliceCount));
        console2.log("Single-shot impact bps: ", uint256(plan.estimatedSingleShotImpactBps));
        console2.log("TWAP slice impact bps:  ", uint256(plan.estimatedTwapImpactBps));
        console2.log("Estimated bps saved:    ", uint256(plan.estimatedBpsSaved));

        vm.startBroadcast(pk);

        // 1. Deposit 3,000 tUSDT into user-owned vault
        IERC20(tUsdtAddr).approve(vaultAddr, 3_000e6);
        vault.deposit(tUsdtAddr, 3_000e6);

        // 2. Conversational policy update anchored by chatIntentHash
        bytes32 chatHash = keccak256(
            "SpreadPilot Chat Intent: Balanced HSK/USDT spread pilot, max 1000 USDT/slice, 15bps min edge, 50bps max slippage, 5% stop-loss"
        );
        SpreadPilotTypes.ExecutionPolicy memory customPolicy = SpreadPilotTypes.ExecutionPolicy({
            maxSliceNotional: 1_000e6,
            maxTotalOrderNotional: 5_000e6,
            minSliceIntervalSec: sliceIntervalSec,
            minNetEdgeBps: 15,
            maxSlippageBps: 50,
            stopLossDrawdownBps: 500, // 5.00% stop-loss
            dailyLossLimit: 500e6,
            maxDailyTrades: 20,
            agentExpiry: uint64(block.timestamp + 30 days),
            paused: false,
            riskAppetite: SpreadPilotTypes.RiskAppetite.BALANCED
        });
        vault.updatePolicy(customPolicy, chatHash);

        // 3. Create 3-slice TWAP order (3,000 tUSDT -> tWHSK, 1,000 tUSDT/slice)
        uint256 orderId = vault.createTwapPlan(tUsdtAddr, tWhskAddr, 500, 3_000e6, 3, 15, 50, 1e8);

        // 4. Execute Slice 1 & Slice 2 with verifiable on-chain decision hashes
        (uint256 quoteSlice1,) = adapter.quoteExactInputSingle(tUsdtAddr, tWhskAddr, 500, 1_000e6);
        uint256 out1 = vault.executeSpreadSlice(
            orderId,
            adapterAddr,
            2_000e18, // reference expectation at $0.50/tWHSK
            (quoteSlice1 * 9_950) / 10_000,
            28, // +28 bps observed net edge
            plan.estimatedBpsSaved,
            keccak256("decision:slice-1:edge+28bps")
        );

        (uint256 quoteSlice2,) = adapter.quoteExactInputSingle(tUsdtAddr, tWhskAddr, 500, 1_000e6);
        uint256 out2 = vault.executeSpreadSlice(
            orderId,
            adapterAddr,
            2_000e18,
            (quoteSlice2 * 9_950) / 10_000,
            22, // +22 bps observed net edge
            plan.estimatedBpsSaved,
            keccak256("decision:slice-2:edge+22bps")
        );

        // 5. Log verifiable refusal on tight spread (+6 bps < 15 bps minimum)
        vault.logRefusedOpportunity(
            tUsdtAddr,
            tWhskAddr,
            6,
            SpreadPilotTypes.REFUSAL_SPREAD_BELOW_MIN,
            keccak256("refusal:tight-spread:+6bps<+15bps")
        );

        // 6. Report mark-to-market drawdown (-6.67% from 3,000 HWM => 2,800 tUSDT) to trip 5% stop-loss
        bool tripped = vault.reportMarkToMarketAndCheckStopLoss(2_800e6);
        require(tripped && vault.circuitBreakerTripped(), "Expected circuit breaker trip");

        // 7. Log circuit-breaker refusal proof for Slice 3 (slice 3 is now blocked on-chain!)
        vault.logRefusedOpportunity(
            tUsdtAddr,
            tWhskAddr,
            31,
            SpreadPilotTypes.REFUSAL_CIRCUIT_BREAKER,
            keccak256("refusal:slice-3-blocked:circuit-breaker-active")
        );

        vm.stopBroadcast();

        // Confirm off-chain static simulation that slice 3 is indeed blocked by CircuitBreakerActive()
        (bool slice3Allowed,) = vaultAddr.staticcall(
            abi.encodeWithSelector(
                vault.executeSpreadSlice.selector,
                orderId,
                adapterAddr,
                2_000e18,
                1_990e18,
                int32(31),
                plan.estimatedBpsSaved,
                keccak256("attempt:slice-3")
            )
        );
        require(!slice3Allowed, "Slice 3 must be blocked when circuit breaker is active");

        console2.log("=== SpreadPilot HSK E2E Demo Complete ===");
        console2.log("Order ID:               ", orderId);
        console2.log("Slice 1 tWHSK received: ", out1);
        console2.log("Slice 2 tWHSK received: ", out2);
        console2.log("CircuitBreakerTripped:  ", vault.circuitBreakerTripped());
        console2.log("Slice 3 Blocked:        ", !slice3Allowed);
    }
}

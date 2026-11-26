// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {HSKSwapLiquidityLens} from "../src/HSKSwapLiquidityLens.sol";
import {SpreadPilotVault} from "../src/SpreadPilotVault.sol";
import {SpreadPilotTypes} from "../src/SpreadPilotTypes.sol";
import {TestnetMintableERC20} from "../src/TestnetMintableERC20.sol";

contract SpreadPilotFuzzTest is Test {
    address internal owner = makeAddr("owner");
    address internal agent = makeAddr("agent");

    HSKSwapLiquidityLens internal lens;
    TestnetMintableERC20 internal tUSDT;
    TestnetMintableERC20 internal tWHSK;
    SpreadPilotVault internal vault;

    function setUp() public {
        vm.warp(1_760_000_000);
        lens = new HSKSwapLiquidityLens();
        tUSDT = new TestnetMintableERC20("Testnet USDT", "tUSDT", 6);
        tWHSK = new TestnetMintableERC20("Testnet WHSK", "tWHSK", 18);
        vault = new SpreadPilotVault(owner, address(tUSDT));

        vm.startPrank(owner);
        vault.setAllowedToken(address(tWHSK), true);
        vault.setAuthorizedAgent(agent, uint64(block.timestamp + 30 days));
        vm.stopPrank();
    }

    /// @notice Fuzzes HSKSwapLiquidityLens.estimateSlicePlan across the full input domain.
    function testFuzz_EstimateSlicePlan_Invariants(
        uint256 totalAmountIn,
        uint128 poolLiquidity,
        uint24 feeBps,
        uint16 maxImpactBps,
        uint256 maxSliceCap
    ) public view {
        (
            uint16 sliceCount,
            uint256 sliceAmountIn,
            uint16 singleShotImpactBps,
            uint16 twapImpactBps,
            uint16 bpsSaved
        ) = lens.estimateSlicePlan(totalAmountIn, poolLiquidity, feeBps, maxImpactBps, maxSliceCap);

        // Universal monotonicity & exact savings conservation
        assertLe(twapImpactBps, singleShotImpactBps);
        assertEq(bpsSaved, singleShotImpactBps - twapImpactBps);
        assertLe(singleShotImpactBps, 10_000);

        if (totalAmountIn == 0) {
            assertEq(sliceCount, 0);
            assertEq(sliceAmountIn, 0);
            assertEq(singleShotImpactBps, 0);
            assertEq(twapImpactBps, 0);
            assertEq(bpsSaved, 0);
            return;
        }

        // Non-zero order bounds
        assertGe(sliceCount, 1);
        assertLe(sliceCount, lens.MAX_SLICES());
        assertLe(sliceAmountIn, totalAmountIn);
        assertGt(sliceAmountIn, 0);

        // Ceiling coverage: sliceCount * sliceAmountIn >= totalAmountIn (check safely without overflow)
        if (sliceAmountIn <= type(uint256).max / uint256(sliceCount)) {
            assertGe(sliceAmountIn * uint256(sliceCount), totalAmountIn);
        }

        // When not saturated at MAX_SLICES, both maxSliceCap and maxImpactBps MUST be satisfied!
        if (sliceCount < lens.MAX_SLICES()) {
            if (maxSliceCap > 0) {
                assertLe(sliceAmountIn, maxSliceCap);
            }
            if (poolLiquidity > 0 && maxImpactBps > 0 && maxImpactBps < 10_000) {
                assertLe(twapImpactBps, maxImpactBps);
            }
        }
    }

    /// @notice Fuzzes sqrtPriceX96 -> price1e8 monotonicity for realistic V3 pool prices.
    function testFuzz_SqrtPriceX96ToPrice1e8_Monotonic(uint128 sqrtA, uint128 sqrtB) public view {
        // Bound to realistic sqrt prices avoiding 10^20*price overflow (up to ~$1e15 per token)
        uint160 a = uint160(bound(uint256(sqrtA), 1e12, 1e35));
        uint160 b = uint160(bound(uint256(sqrtB), uint256(a), 1e35));

        uint256 priceA = lens.sqrtPriceX96ToPrice1e8(a, 18, 6);
        uint256 priceB = lens.sqrtPriceX96ToPrice1e8(b, 18, 6);
        assertLe(priceA, priceB);
    }

    /// @notice Fuzzes policy validation bounds on SpreadPilotVault.updatePolicy.
    function testFuzz_PolicyUpdateBounds(
        uint256 maxSlice,
        uint256 maxTotal,
        uint16 maxSlippage,
        uint16 stopLoss,
        uint16 maxDailyTrades,
        bytes32 chatHash
    ) public {
        SpreadPilotTypes.ExecutionPolicy memory p = SpreadPilotTypes.ExecutionPolicy({
            maxSliceNotional: maxSlice,
            maxTotalOrderNotional: maxTotal,
            minSliceIntervalSec: 30,
            minNetEdgeBps: 10,
            maxSlippageBps: maxSlippage,
            stopLossDrawdownBps: stopLoss,
            dailyLossLimit: 500e6,
            maxDailyTrades: maxDailyTrades,
            agentExpiry: uint64(block.timestamp + 1 days),
            paused: false,
            riskAppetite: SpreadPilotTypes.RiskAppetite.BALANCED
        });

        bool valid = maxSlice > 0 && maxTotal >= maxSlice && maxSlippage <= vault.MAX_POLICY_SLIPPAGE_BPS()
            && stopLoss > 0 && stopLoss <= vault.MAX_POLICY_DRAWDOWN_BPS() && maxDailyTrades > 0;

        uint256 versionBefore = vault.policyVersion();
        vm.prank(owner);
        if (!valid) {
            vm.expectRevert();
            vault.updatePolicy(p, chatHash);
            assertEq(vault.policyVersion(), versionBefore);
        } else {
            vault.updatePolicy(p, chatHash);
            assertEq(vault.policyVersion(), versionBefore + 1);
            assertEq(vault.lastChatIntentHash(), chatHash);
            assertEq(vault.getPolicy().maxSliceNotional, maxSlice);
            assertEq(vault.getPolicy().stopLossDrawdownBps, stopLoss);
        }
    }

    /// @notice Fuzzes mark-to-market stop-loss drawdown trip threshold precision.
    function testFuzz_MarkToMarketStopLoss(uint96 hwmRaw, uint96 currentRaw, uint16 stopLossBpsRaw) public {
        uint256 hwm = bound(uint256(hwmRaw), 1e6, 1_000_000_000e6);
        uint256 currentVal = bound(uint256(currentRaw), 0, 2_000_000_000e6);
        uint16 stopLossBps = uint16(bound(uint256(stopLossBpsRaw), 1, 5_000));

        SpreadPilotTypes.ExecutionPolicy memory p = vault.getPolicy();
        p.stopLossDrawdownBps = stopLossBps;

        vm.startPrank(owner);
        vault.updatePolicy(p, keccak256("fuzz-stoploss"));
        vault.setHighWaterMark(hwm);
        vm.stopPrank();

        vm.prank(agent);
        bool tripped = vault.reportMarkToMarketAndCheckStopLoss(currentVal);

        if (currentVal >= hwm) {
            assertFalse(tripped);
            assertFalse(vault.circuitBreakerTripped());
            assertEq(vault.getStats().highWaterMarkQuote, currentVal);
        } else {
            uint256 expectedDrawdownBps = ((hwm - currentVal) * 10_000) / hwm;
            bool shouldTrip = expectedDrawdownBps >= uint256(stopLossBps);
            assertEq(tripped, shouldTrip);
            assertEq(vault.circuitBreakerTripped(), shouldTrip);
            assertEq(vault.getStats().highWaterMarkQuote, hwm);
        }
    }

    /// @notice Fuzzes access control: arbitrary callers & expired agent always rejected.
    function testFuzz_AccessControl_RandomCallerRejected(address caller, uint32 expiryOffset, uint32 extraWarp) public {
        vm.assume(caller != owner && caller != agent && caller != address(0));

        // Random caller cannot touch governance or execution
        vm.prank(caller);
        vm.expectRevert(SpreadPilotVault.NotOwner.selector);
        vault.emergencyPause();

        vm.prank(caller);
        vm.expectRevert(SpreadPilotVault.NotOwner.selector);
        vault.applyRiskPreset(SpreadPilotTypes.RiskAppetite.AGGRESSIVE);

        vm.prank(caller);
        vm.expectRevert(SpreadPilotVault.NotAuthorized.selector);
        vault.logRefusedOpportunity(address(tUSDT), address(tWHSK), 1, 1, keccak256("unauth"));

        vm.prank(caller);
        vm.expectRevert(SpreadPilotVault.NotAuthorized.selector);
        vault.reportMarkToMarketAndCheckStopLoss(100e6);

        // Agent expiry strictly enforced
        uint64 expiry = uint64(vm.getBlockTimestamp() + bound(uint256(expiryOffset), 1, 365 days));
        vm.prank(owner);
        vault.setAuthorizedAgent(agent, expiry);

        uint256 warpAfterExpiry = uint256(expiry) + bound(uint256(extraWarp), 1, 365 days);
        vm.warp(warpAfterExpiry);

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(SpreadPilotVault.AgentExpired.selector, expiry, warpAfterExpiry));
        vault.logRefusedOpportunity(address(tUSDT), address(tWHSK), 1, 1, keccak256("expired"));
    }

    /// @notice Fuzzes TWAP plan notional cap & slice cap enforcement.
    function testFuzz_CreateTwapPlan_NotionalCapsEnforced(uint256 totalAmountInRaw, uint16 slicesRaw) public {
        uint256 totalAmountIn = bound(totalAmountInRaw, 1, 20_000e6);
        uint16 slicesTotal = uint16(bound(uint256(slicesRaw), 1, 120));

        // Fund vault generously so balance isn't the bottleneck
        tUSDT.mint(owner, 25_000e6);
        vm.startPrank(owner);
        tUSDT.approve(address(vault), 25_000e6);
        vault.deposit(address(tUSDT), 25_000e6);
        vm.stopPrank();

        SpreadPilotTypes.ExecutionPolicy memory p = vault.getPolicy();
        uint256 sliceSize = ((totalAmountIn - 1) / uint256(slicesTotal)) + 1;
        bool shouldSucceed = slicesTotal <= vault.MAX_SLICES_PER_ORDER()
            && totalAmountIn <= p.maxTotalOrderNotional && sliceSize <= p.maxSliceNotional;

        vm.prank(agent);
        if (!shouldSucceed) {
            vm.expectRevert();
            vault.createTwapPlan(address(tUSDT), address(tWHSK), 500, totalAmountIn, slicesTotal, 15, 50, 1e8);
        } else {
            uint256 orderId =
                vault.createTwapPlan(address(tUSDT), address(tWHSK), 500, totalAmountIn, slicesTotal, 15, 50, 1e8);
            SpreadPilotTypes.TwapOrder memory ord = vault.getOrder(orderId);
            assertEq(ord.totalAmountIn, totalAmountIn);
            assertEq(ord.sliceSize, sliceSize);
            assertLe(ord.sliceSize, p.maxSliceNotional);
            assertTrue(ord.active);
        }
    }
}

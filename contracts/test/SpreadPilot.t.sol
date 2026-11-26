// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {HSKSwapLiquidityLens} from "../src/HSKSwapLiquidityLens.sol";
import {SpreadPilotVault} from "../src/SpreadPilotVault.sol";
import {SpreadPilotTypes} from "../src/SpreadPilotTypes.sol";
import {TestnetMintableERC20} from "../src/TestnetMintableERC20.sol";
import {TestnetHSKSwapAdapter, TestnetV3Pool} from "../src/TestnetHSKSwapAdapter.sol";

contract SpreadPilotTest is Test {
    address internal owner = makeAddr("owner");
    address internal agent = makeAddr("agent");
    address internal attacker = makeAddr("attacker");

    TestnetMintableERC20 internal tWHSK;
    TestnetMintableERC20 internal tUSDT;
    TestnetMintableERC20 internal tWETH;
    TestnetMintableERC20 internal tWBTC;

    HSKSwapLiquidityLens internal lens;
    TestnetHSKSwapAdapter internal adapter;
    TestnetV3Pool internal whskUsdtPool;
    SpreadPilotVault internal vault;

    // sqrt(0.5e6 / 1e18) * 2^96 = 56_022_770_974_786_139_918_731
    uint160 internal constant WHSK_USDT_SQRT_PRICE_X96 = 56_022_770_974_786_139_918_731;

    function setUp() public {
        vm.warp(1_760_000_000);

        tWHSK = new TestnetMintableERC20("Testnet Wrapped HSK", "tWHSK", 18);
        tUSDT = new TestnetMintableERC20("Testnet Tether USD", "tUSDT", 6);
        tWETH = new TestnetMintableERC20("Testnet Wrapped ETH", "tWETH", 18);
        tWBTC = new TestnetMintableERC20("Testnet Wrapped BTC", "tWBTC", 8);

        lens = new HSKSwapLiquidityLens();
        adapter = new TestnetHSKSwapAdapter();
        whskUsdtPool = new TestnetV3Pool(address(tWHSK), address(tUSDT), 500, WHSK_USDT_SQRT_PRICE_X96, -283_268, 50_000e6);

        // Fund adapter reserves
        tWHSK.mint(address(adapter), 5_000_000e18);
        tUSDT.mint(address(adapter), 5_000_000e6);
        tWETH.mint(address(adapter), 1_000e18);
        tWBTC.mint(address(adapter), 100e8);

        // Configure adapter pair rates (tWHSK = $0.50)
        // 500,000 tUSDT virtual depth => 20 bps impact on 1,000 tUSDT slice vs 60 bps on 3,000 tUSDT single-shot.
        // With +45 bps spread bonus and 5 bps fee, 1,000 tUSDT TWAP slices net +20 bps profit!
        adapter.setPairConfig(address(tUSDT), address(tWHSK), 2e30, 500_000e6, 45);
        adapter.setPairConfig(address(tWHSK), address(tUSDT), 5e5, 1_000_000e18, 45);

        vault = new SpreadPilotVault(owner, address(tUSDT));

        vm.startPrank(owner);
        vault.setAllowedToken(address(tWHSK), true);
        vault.setAllowedToken(address(tWETH), true);
        vault.setAllowedToken(address(tWBTC), true);
        vault.setAllowedRouter(address(adapter), true);
        vault.setAuthorizedAgent(agent, uint64(block.timestamp + 7 days));
        vm.stopPrank();

        // Mint funds to owner
        tUSDT.mint(owner, 100_000e6);
        tWHSK.mint(owner, 200_000e18);
    }

    function _depositUsdt(uint256 amount) internal {
        vm.startPrank(owner);
        tUSDT.approve(address(vault), amount);
        vault.deposit(address(tUSDT), amount);
        vm.stopPrank();
    }

    function _depositWhsk(uint256 amount) internal {
        vm.startPrank(owner);
        tWHSK.approve(address(vault), amount);
        vault.deposit(address(tWHSK), amount);
        vm.stopPrank();
    }

    // ────────────────────────── 1. Governance & Presets ──────────────────────────

    function test_ConstructorAndDefaultBalancedPreset() public view {
        assertEq(vault.owner(), owner);
        assertEq(vault.quoteToken(), address(tUSDT));
        assertEq(vault.quoteDecimals(), 6);
        assertTrue(vault.allowedTokens(address(tUSDT)));
        assertTrue(vault.isAgentActive());

        SpreadPilotTypes.ExecutionPolicy memory p = vault.getPolicy();
        assertEq(uint8(p.riskAppetite), uint8(SpreadPilotTypes.RiskAppetite.BALANCED));
        assertEq(p.maxSliceNotional, 1_500e6);
        assertEq(p.maxTotalOrderNotional, 10_000e6);
        assertEq(p.minSliceIntervalSec, 45);
        assertEq(p.minNetEdgeBps, 15);
        assertEq(p.maxSlippageBps, 60);
        assertEq(p.stopLossDrawdownBps, 500);
        assertEq(p.dailyLossLimit, 1_000e6);
        assertEq(p.maxDailyTrades, 30);
        assertFalse(p.paused);
    }

    function test_RiskPresets_ConservativeBalancedAggressive() public {
        uint64 expiryBefore = vault.getPolicy().agentExpiry;

        vm.startPrank(owner);
        vault.emergencyPause();
        vault.applyRiskPreset(SpreadPilotTypes.RiskAppetite.CONSERVATIVE);

        SpreadPilotTypes.ExecutionPolicy memory c = vault.getPolicy();
        assertEq(uint8(c.riskAppetite), uint8(SpreadPilotTypes.RiskAppetite.CONSERVATIVE));
        assertEq(c.maxSliceNotional, 500e6);
        assertEq(c.minNetEdgeBps, 25);
        assertEq(c.stopLossDrawdownBps, 200);
        assertEq(c.agentExpiry, expiryBefore);
        assertTrue(c.paused); // preset preserves pause state

        vault.applyRiskPreset(SpreadPilotTypes.RiskAppetite.AGGRESSIVE);
        SpreadPilotTypes.ExecutionPolicy memory a = vault.getPolicy();
        assertEq(uint8(a.riskAppetite), uint8(SpreadPilotTypes.RiskAppetite.AGGRESSIVE));
        assertEq(a.maxSliceNotional, 5_000e6);
        assertEq(a.maxTotalOrderNotional, 25_000e6);
        assertEq(a.minSliceIntervalSec, 15);
        assertEq(a.minNetEdgeBps, 8);
        assertEq(a.maxSlippageBps, 120);
        assertEq(a.stopLossDrawdownBps, 1_000);
        assertEq(vault.policyVersion(), 3);
        vm.stopPrank();
    }

    function test_UpdatePolicy_ConversationalIntentHashAndValidation() public {
        bytes32 chatHash = keccak256("Keep slices under $1,000, min edge 20bps, stop-loss 4%");
        SpreadPilotTypes.ExecutionPolicy memory p = vault.getPolicy();
        p.maxSliceNotional = 1_000e6;
        p.maxTotalOrderNotional = 6_000e6;
        p.minNetEdgeBps = 20;
        p.stopLossDrawdownBps = 400;

        vm.prank(owner);
        vault.updatePolicy(p, chatHash);

        assertEq(vault.lastChatIntentHash(), chatHash);
        assertEq(vault.policyVersion(), 2);
        assertEq(vault.getPolicy().maxSliceNotional, 1_000e6);
        assertEq(vault.getPolicy().minNetEdgeBps, 20);

        // Invalid policy checks
        vm.startPrank(owner);
        p.maxSliceNotional = 0;
        vm.expectRevert(abi.encodeWithSelector(SpreadPilotVault.InvalidPolicy.selector, "maxSliceNotional=0"));
        vault.updatePolicy(p, chatHash);

        p.maxSliceNotional = 7_000e6;
        vm.expectRevert(abi.encodeWithSelector(SpreadPilotVault.InvalidPolicy.selector, "maxTotal<maxSlice"));
        vault.updatePolicy(p, chatHash);

        p.maxSliceNotional = 1_000e6;
        p.maxSlippageBps = 2_001;
        vm.expectRevert(abi.encodeWithSelector(SpreadPilotVault.InvalidPolicy.selector, "maxSlippage>2000"));
        vault.updatePolicy(p, chatHash);

        p.maxSlippageBps = 50;
        p.stopLossDrawdownBps = 0;
        vm.expectRevert(abi.encodeWithSelector(SpreadPilotVault.InvalidPolicy.selector, "invalidStopLoss"));
        vault.updatePolicy(p, chatHash);

        p.stopLossDrawdownBps = 5_001;
        vm.expectRevert(abi.encodeWithSelector(SpreadPilotVault.InvalidPolicy.selector, "invalidStopLoss"));
        vault.updatePolicy(p, chatHash);

        p.stopLossDrawdownBps = 400;
        p.maxDailyTrades = 0;
        vm.expectRevert(abi.encodeWithSelector(SpreadPilotVault.InvalidPolicy.selector, "maxDailyTrades=0"));
        vault.updatePolicy(p, chatHash);
        vm.stopPrank();
    }

    function test_DepositAndWithdraw_NonCustodialEvenWhenPausedOrTripped() public {
        _depositUsdt(4_000e6);
        assertEq(tUSDT.balanceOf(address(vault)), 4_000e6);
        assertEq(vault.getStats().highWaterMarkQuote, 4_000e6);

        // Pause AND trip circuit breaker
        vm.prank(owner);
        vault.emergencyPause();
        vm.prank(agent);
        bool tripped = vault.reportMarkToMarketAndCheckStopLoss(3_500e6);
        assertTrue(tripped);
        assertTrue(vault.circuitBreakerTripped());

        // Non-owner cannot withdraw
        vm.prank(attacker);
        vm.expectRevert(SpreadPilotVault.NotOwner.selector);
        vault.withdraw(address(tUSDT), 1_000e6, attacker);

        // Owner CAN ALWAYS withdraw full funds even while paused + tripped
        uint256 ownerBalBefore = tUSDT.balanceOf(owner);
        vm.prank(owner);
        vault.withdraw(address(tUSDT), 4_000e6, owner);
        assertEq(tUSDT.balanceOf(owner) - ownerBalBefore, 4_000e6);
        assertEq(tUSDT.balanceOf(address(vault)), 0);
        assertEq(vault.getStats().highWaterMarkQuote, 0);
    }

    // ────────────────────────── 2. HSKSwapLiquidityLens ──────────────────────────

    function test_LiquidityLens_InspectPoolAndSqrtPriceMath() public view {
        SpreadPilotTypes.PoolSnapshot memory snap = lens.inspectPool(address(whskUsdtPool), 18, 6);
        assertEq(snap.token0, address(tWHSK));
        assertEq(snap.token1, address(tUSDT));
        assertEq(snap.fee, 500);
        assertEq(snap.liquidity, 50_000e6);
        // $0.50 scaled by 1e8 = 50_000_000 (within 1 wei rounding from integer sqrtPriceX96)
        assertApproxEqAbs(snap.spotPrice1e8, 50_000_000, 2);

        // Reverse decimals check: token0 = 6 dec, token1 = 18 dec, price = 2.0 WHSK per USDT
        // sqrt(2e12) * 2^96 = 1_414_213.562373 * 7.92281625e28 = 112_045_541_949_572_279_837_463_876_454_916_096
        uint160 revSqrt = 112_045_541_949_572_279_837_463_876_454_916_096;
        uint256 revPrice = lens.sqrtPriceX96ToPrice1e8(revSqrt, 6, 18);
        assertApproxEqAbs(revPrice, 200_000_000, 10);

        // One-call previewOrderOnPool
        (SpreadPilotTypes.PoolSnapshot memory snap2, SpreadPilotTypes.SlicePlan memory plan) =
            lens.previewOrderOnPool(address(whskUsdtPool), 18, 6, 5_000e6, 250, 1_500e6);
        assertEq(snap2.fee, 500);
        assertEq(plan.sliceCount, 4);
        assertEq(plan.sliceAmountIn, 1_250e6);
        assertLe(plan.estimatedTwapImpactBps, 250);
        assertGt(plan.estimatedBpsSaved, 500);
    }

    function test_LiquidityLens_EstimateSlicePlan_ThinPoolSavesImpact() public view {
        (uint16 slices, uint256 sliceAmt, uint16 singleBps, uint16 twapBps, uint16 savedBps) =
            lens.estimateSlicePlan(5_000e6, 50_000e6, 5, 250, 1_500e6);

        assertEq(slices, 4);
        assertEq(sliceAmt, 1_250e6);
        assertEq(singleBps, 909);
        assertEq(twapBps, 244);
        assertEq(savedBps, 665);

        // Zero amount edge case
        (uint16 zSlices, uint256 zAmt, uint16 zSingle, uint16 zTwap, uint16 zSaved) =
            lens.estimateSlicePlan(0, 50_000e6, 5, 250, 1_500e6);
        assertEq(zSlices, 0);
        assertEq(zAmt, 0);
        assertEq(zSingle, 0);
        assertEq(zTwap, 0);
        assertEq(zSaved, 0);

        // Zero liquidity edge case caps cleanly at MAX_SLICES (100)
        (uint16 zeroLiqSlices,, uint16 zeroLiqSingle, uint16 zeroLiqTwap, uint16 zeroLiqSaved) =
            lens.estimateSlicePlan(1_000e6, 0, 5, 100, 1_000e6);
        assertEq(zeroLiqSlices, 100);
        assertEq(zeroLiqSingle, 10_000);
        assertEq(zeroLiqTwap, 10_000);
        assertEq(zeroLiqSaved, 0);
    }

    // ────────────────────────── 3. TWAP Spread Execution & Balance Delta ──────────────────────────

    function test_TwapExecution_MultiSliceRealSwapBalanceDeltaAndAllowanceReset() public {
        _depositUsdt(3_000e6);

        vm.prank(agent);
        uint256 orderId = vault.createTwapPlan(address(tUSDT), address(tWHSK), 500, 3_000e6, 3, 15, 50, 1e8);
        assertEq(vault.activeOrderCount(), 1);

        SpreadPilotTypes.TwapOrder memory ord = vault.getOrder(orderId);
        assertEq(ord.sliceSize, 1_000e6);
        assertEq(ord.remainingAmountIn, 3_000e6);
        assertTrue(ord.active);

        uint256 totalWhskOut;
        for (uint256 i = 0; i < 3; i++) {
            if (i > 0) skip(45);
            uint256 beforeBal = tWHSK.balanceOf(address(vault));

            vm.prank(agent);
            uint256 out = vault.executeSpreadSlice(
                orderId,
                address(adapter),
                2_000e18,
                1_990e18,
                25,
                180,
                keccak256(abi.encodePacked("slice", i))
            );

            assertEq(tWHSK.balanceOf(address(vault)) - beforeBal, out);
            assertGt(out, 2_000e18); // +45 bps spread bonus > ~20 bps slice impact + 5 bps fee
            assertEq(tUSDT.allowance(address(vault), address(adapter)), 0); // allowance strictly reset
            totalWhskOut += out;
        }

        ord = vault.getOrder(orderId);
        assertFalse(ord.active);
        assertEq(ord.remainingAmountIn, 0);
        assertEq(ord.slicesExecuted, 3);
        assertEq(vault.activeOrderCount(), 0);
        assertEq(tUSDT.balanceOf(address(vault)), 0);

        SpreadPilotTypes.PositionStats memory st = vault.getStats();
        assertEq(st.totalVolumeIn, 3_000e6);
        assertEq(st.totalVolumeOut, totalWhskOut);
        assertEq(st.totalSlicesExecuted, 3);
        assertEq(st.tradesToday, 3);
        assertEq(st.cumulativeSlippageSavedBps, 540);
        assertGt(st.realizedPnlQuote, 0);
    }

    function test_TwapExecution_NonQuoteTokenInMultiDecimalAccounting() public {
        // 4,000 tWHSK (18 dec) at $0.50 = $2,000 quote notional -> 2 slices of 2,000 tWHSK ($1,000 <= $1,500 cap)
        _depositWhsk(4_000e18);

        vm.prank(agent);
        uint256 orderId = vault.createTwapPlan(address(tWHSK), address(tUSDT), 500, 4_000e18, 2, 15, 50, 50_000_000);

        vm.prank(agent);
        uint256 usdtOut = vault.executeSpreadSlice(
            orderId, address(adapter), 1_000e6, 995e6, 20, 120, keccak256("whsk-to-usdt-slice-1")
        );

        assertGt(usdtOut, 1_000e6);
        assertEq(tUSDT.balanceOf(address(vault)), usdtOut);
        assertEq(vault.getStats().realizedPnlQuote, int256(usdtOut - 1_000e6));
        assertEq(vault.getStats().highWaterMarkQuote, usdtOut);
    }

    // ────────────────────────── 4. Guardrails Enforcement ──────────────────────────

    function test_EnforceCooldown_MinSliceIntervalSec() public {
        _depositUsdt(2_000e6);

        vm.prank(agent);
        uint256 orderId = vault.createTwapPlan(address(tUSDT), address(tWHSK), 500, 2_000e6, 2, 15, 50, 1e8);

        vm.prank(agent);
        vault.executeSpreadSlice(orderId, address(adapter), 2_000e18, 1_990e18, 20, 100, keccak256("s1"));

        uint256 expectedNext = block.timestamp + 45;
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(SpreadPilotVault.SliceCooldownActive.selector, expectedNext));
        vault.executeSpreadSlice(orderId, address(adapter), 2_000e18, 1_990e18, 20, 100, keccak256("s2-early"));

        vm.warp(expectedNext);
        vm.prank(agent);
        vault.executeSpreadSlice(orderId, address(adapter), 2_000e18, 1_990e18, 20, 100, keccak256("s2-ok"));
        assertEq(vault.getOrder(orderId).slicesExecuted, 2);
    }

    function test_EnforceMinNetEdgeBps() public {
        _depositUsdt(1_000e6);

        vm.prank(agent);
        uint256 orderId = vault.createTwapPlan(address(tUSDT), address(tWHSK), 500, 1_000e6, 1, 20, 50, 1e8);

        // Policy min is 15 bps, order min is 20 bps -> 19 bps must revert
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(SpreadPilotVault.InsufficientNetEdge.selector, int32(19), int32(20)));
        vault.executeSpreadSlice(orderId, address(adapter), 2_000e18, 1_990e18, 19, 50, keccak256("low-edge"));
    }

    function test_EnforceMaxSlippageBps_AndMinAmountOut() public {
        _depositUsdt(1_000e6);

        vm.prank(agent);
        uint256 orderId = vault.createTwapPlan(address(tUSDT), address(tWHSK), 500, 1_000e6, 1, 15, 50, 1e8);

        // Shift adapter to adverse -120 bps spread (~145 bps total slippage > 50 bps policy ceiling)
        adapter.setPairConfig(address(tUSDT), address(tWHSK), 2e30, 50_000e6, -120);

        // Even if caller passes a loose minAmountOut = 1, vault enforces realized slippage vs expectedOutAtRef <= 50 bps!
        vm.prank(agent);
        vm.expectRevert(); // MaxSlippageExceeded
        vault.executeSpreadSlice(orderId, address(adapter), 2_000e18, 1, 25, 50, keccak256("high-slippage"));

        // Strict minAmountOut also reverts inside router/vault
        vm.prank(agent);
        vm.expectRevert();
        vault.executeSpreadSlice(orderId, address(adapter), 2_000e18, 1_999e18, 25, 50, keccak256("strict-min-out"));
    }

    function test_EnforceDailyTradeCap_AndNextDayRollover() public {
        _depositUsdt(3_000e6);

        SpreadPilotTypes.ExecutionPolicy memory p = vault.getPolicy();
        p.maxDailyTrades = 2;
        p.minSliceIntervalSec = 1;
        vm.prank(owner);
        vault.updatePolicy(p, keccak256("cap=2"));

        vm.prank(agent);
        uint256 orderId = vault.createTwapPlan(address(tUSDT), address(tWHSK), 500, 3_000e6, 3, 15, 50, 1e8);

        vm.prank(agent);
        vault.executeSpreadSlice(orderId, address(adapter), 2_000e18, 1_990e18, 25, 100, keccak256("d1-s1"));
        skip(2);
        vm.prank(agent);
        vault.executeSpreadSlice(orderId, address(adapter), 2_000e18, 1_990e18, 25, 100, keccak256("d1-s2"));

        skip(2);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(SpreadPilotVault.DailyTradeLimitReached.selector, uint16(2), uint16(2)));
        vault.executeSpreadSlice(orderId, address(adapter), 2_000e18, 1_990e18, 25, 100, keccak256("d1-s3-blocked"));

        // Warp to next UTC day -> daily counter rolls over and slice 3 succeeds!
        skip(1 days);
        vm.prank(agent);
        vault.executeSpreadSlice(orderId, address(adapter), 2_000e18, 1_990e18, 25, 100, keccak256("d2-s3-ok"));
        assertEq(vault.getStats().tradesToday, 1);
        assertEq(vault.getOrder(orderId).slicesExecuted, 3);
    }

    // ────────────────────────── 5. Circuit Breakers ──────────────────────────

    function test_AutoTripCircuitBreaker_OnDailyLossLimit() public {
        _depositUsdt(3_000e6);

        SpreadPilotTypes.ExecutionPolicy memory p = vault.getPolicy();
        p.dailyLossLimit = 4e6; // $4 daily loss limit
        p.maxSlippageBps = 100; // allow up to 1% slippage per slice so trade executes and logs loss
        p.minSliceIntervalSec = 1;
        vm.prank(owner);
        vault.updatePolicy(p, keccak256("tight-daily-loss"));

        // Slight adverse spread (-35 bps) -> 20 bps impact + 5 bps fee + 35 bps adverse = 60 bps shortfall
        // (~$6 loss on $1,000 slice > $4 dailyLossLimit, while staying within 100 bps maxSlippageBps)
        adapter.setPairConfig(address(tUSDT), address(tWHSK), 2e30, 500_000e6, -35);

        vm.prank(agent);
        uint256 orderId = vault.createTwapPlan(address(tUSDT), address(tWHSK), 500, 2_000e6, 2, 15, 100, 1e8);

        vm.prank(agent);
        vault.executeSpreadSlice(orderId, address(adapter), 2_000e18, 1_980e18, 20, 50, keccak256("loss-slice"));

        assertTrue(vault.circuitBreakerTripped());
        assertGe(vault.getStats().dailyLossQuote, 4e6);

        skip(10);
        vm.prank(agent);
        vm.expectRevert(SpreadPilotVault.CircuitBreakerActive.selector);
        vault.executeSpreadSlice(orderId, address(adapter), 2_000e18, 1_980e18, 20, 50, keccak256("blocked-slice"));
    }

    function test_StopLossCircuitBreaker_MarkToMarketTripLockAndOwnerReset() public {
        _depositUsdt(3_000e6);

        // Mark-to-market -3.33% (< 5.00% BALANCED stop-loss): does NOT trip
        vm.prank(agent);
        bool tripped1 = vault.reportMarkToMarketAndCheckStopLoss(2_900e6);
        assertFalse(tripped1);
        assertFalse(vault.circuitBreakerTripped());

        // Mark-to-market -5.00% (== 500 bps stop-loss): TRIPS circuit breaker
        vm.prank(agent);
        bool tripped2 = vault.reportMarkToMarketAndCheckStopLoss(2_850e6);
        assertTrue(tripped2);
        assertTrue(vault.circuitBreakerTripped());
        assertFalse(vault.isAgentActive());

        // Creating new TWAP blocked while tripped
        vm.prank(agent);
        vm.expectRevert(SpreadPilotVault.CircuitBreakerActive.selector);
        vault.createTwapPlan(address(tUSDT), address(tWHSK), 500, 1_000e6, 1, 15, 50, 1e8);

        // Non-owner cannot reset
        vm.prank(agent);
        vm.expectRevert(SpreadPilotVault.NotOwner.selector);
        vault.resetCircuitBreaker();

        // Owner resets circuit breaker -> operational again
        vm.prank(owner);
        vault.resetCircuitBreaker();
        assertFalse(vault.circuitBreakerTripped());
        assertTrue(vault.isAgentActive());

        vm.prank(agent);
        uint256 orderId = vault.createTwapPlan(address(tUSDT), address(tWHSK), 500, 1_000e6, 1, 15, 50, 1e8);
        assertEq(orderId, 1);
    }

    // ────────────────────────── 6. Access Control, Refusals & Cancellation ──────────────────────────

    function test_AccessControl_UnauthorizedCallerExpiredAgentUnapprovedRouterUnapprovedToken() public {
        _depositUsdt(2_000e6);

        // Unauthorized caller cannot create TWAP or log refusal
        vm.prank(attacker);
        vm.expectRevert(SpreadPilotVault.NotAuthorized.selector);
        vault.createTwapPlan(address(tUSDT), address(tWHSK), 500, 1_000e6, 1, 15, 50, 1e8);

        vm.prank(attacker);
        vm.expectRevert(SpreadPilotVault.NotAuthorized.selector);
        vault.logRefusedOpportunity(address(tUSDT), address(tWHSK), 5, 1, keccak256("spoof"));

        // Unapproved token rejected
        TestnetMintableERC20 rogueToken = new TestnetMintableERC20("Rogue", "RUG", 18);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(SpreadPilotVault.TokenNotAllowed.selector, address(rogueToken)));
        vault.createTwapPlan(address(tUSDT), address(rogueToken), 500, 1_000e6, 1, 15, 50, 1e8);

        // Valid plan created, then unapproved router rejected on execution
        vm.prank(agent);
        uint256 orderId = vault.createTwapPlan(address(tUSDT), address(tWHSK), 500, 1_000e6, 1, 15, 50, 1e8);

        address rogueRouter = makeAddr("rogueRouter");
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(SpreadPilotVault.RouterNotAllowed.selector, rogueRouter));
        vault.executeSpreadSlice(orderId, rogueRouter, 2_000e18, 1_990e18, 25, 100, keccak256("bad-router"));

        // Paused vault blocks execution
        vm.prank(owner);
        vault.emergencyPause();
        vm.prank(agent);
        vm.expectRevert(SpreadPilotVault.VaultPaused.selector);
        vault.executeSpreadSlice(orderId, address(adapter), 2_000e18, 1_990e18, 25, 100, keccak256("paused"));

        vm.prank(owner);
        vault.unpause();

        // Expired agent rejected
        uint64 expiry = vault.getPolicy().agentExpiry;
        vm.warp(uint256(expiry) + 1);
        assertFalse(vault.isAgentActive());

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(SpreadPilotVault.AgentExpired.selector, expiry, block.timestamp));
        vault.executeSpreadSlice(orderId, address(adapter), 2_000e18, 1_990e18, 25, 100, keccak256("expired"));
    }

    function test_RefusalLogging_VerifiableOnChainWithoutMovingFunds() public {
        _depositUsdt(1_500e6);
        uint256 balBefore = tUSDT.balanceOf(address(vault));

        bytes32 hash = keccak256("refused:spread-6bps-below-15bps");
        vm.expectEmit(true, true, true, true);
        emit SpreadPilotVault.OpportunityRefused(
            agent,
            address(tUSDT),
            address(tWHSK),
            6,
            SpreadPilotTypes.REFUSAL_SPREAD_BELOW_MIN,
            hash,
            uint64(block.timestamp)
        );

        vm.prank(agent);
        vault.logRefusedOpportunity(
            address(tUSDT), address(tWHSK), 6, SpreadPilotTypes.REFUSAL_SPREAD_BELOW_MIN, hash
        );

        assertEq(vault.getStats().totalRefusalsLogged, 1);
        assertEq(tUSDT.balanceOf(address(vault)), balBefore);
    }

    function test_CancelTwapPlan_AndMaxActiveOrders() public {
        _depositUsdt(15_000e6);

        vm.startPrank(agent);
        for (uint256 i = 0; i < 10; i++) {
            vault.createTwapPlan(address(tUSDT), address(tWHSK), 500, 1_000e6, 2, 15, 50, 1e8);
        }
        assertEq(vault.activeOrderCount(), 10);

        vm.expectRevert(SpreadPilotVault.MaxActiveOrdersReached.selector);
        vault.createTwapPlan(address(tUSDT), address(tWHSK), 500, 1_000e6, 2, 15, 50, 1e8);

        vault.cancelTwapPlan(1);
        assertEq(vault.activeOrderCount(), 9);
        assertTrue(vault.getOrder(1).cancelled);
        assertFalse(vault.getOrder(1).active);

        vm.expectRevert(abi.encodeWithSelector(SpreadPilotVault.OrderNotActive.selector, 1));
        vault.executeSpreadSlice(1, address(adapter), 1_000e18, 990e18, 25, 100, keccak256("cancelled"));
        vm.stopPrank();
    }

    // ────────────────────────── 7. Full E2E Demo Scenario ──────────────────────────

    function test_FullE2EDemoScenario_MatchesHackathonScript() public {
        // Step 1: Deposit 3,000 tUSDT
        _depositUsdt(3_000e6);

        // Step 2: Update policy from chat intent hash
        bytes32 chatHash = keccak256("Balanced HSK spread pilot: 1000 USDT/slice, 15bps min edge, 5% stop-loss");
        SpreadPilotTypes.ExecutionPolicy memory custom = vault.getPolicy();
        custom.maxSliceNotional = 1_000e6;
        custom.maxTotalOrderNotional = 5_000e6;
        custom.minSliceIntervalSec = 30;
        custom.minNetEdgeBps = 15;
        custom.maxSlippageBps = 50;
        custom.stopLossDrawdownBps = 500;
        vm.prank(owner);
        vault.updatePolicy(custom, chatHash);

        // Step 3: Lens computes optimal TWAP slicing & agent creates 3-slice TWAP
        (, SpreadPilotTypes.SlicePlan memory plan) =
            lens.previewOrderOnPool(address(whskUsdtPool), 18, 6, 3_000e6, 250, 1_000e6);
        assertEq(plan.sliceCount, 3);
        assertGt(plan.estimatedBpsSaved, 300);

        vm.prank(agent);
        uint256 orderId = vault.createTwapPlan(address(tUSDT), address(tWHSK), 500, 3_000e6, 3, 15, 50, 1e8);

        // Step 4: Execute slice 1 & slice 2
        vm.prank(agent);
        vault.executeSpreadSlice(
            orderId, address(adapter), 2_000e18, 1_990e18, 28, plan.estimatedBpsSaved, keccak256("demo-s1")
        );

        skip(30);
        vm.prank(agent);
        vault.executeSpreadSlice(
            orderId, address(adapter), 2_000e18, 1_990e18, 22, plan.estimatedBpsSaved, keccak256("demo-s2")
        );

        // Step 5: Log refusal on tight spread
        vm.prank(agent);
        vault.logRefusedOpportunity(
            address(tUSDT), address(tWHSK), 6, SpreadPilotTypes.REFUSAL_SPREAD_BELOW_MIN, keccak256("demo-refuse")
        );

        // Step 6: Trigger stop-loss drawdown (2,800 vs 3,000 HWM = 6.67% >= 5.00%)
        vm.prank(agent);
        bool tripped = vault.reportMarkToMarketAndCheckStopLoss(2_800e6);
        assertTrue(tripped);
        assertTrue(vault.circuitBreakerTripped());

        // Step 7: Verify breaker blocks slice 3
        skip(30);
        vm.prank(agent);
        vm.expectRevert(SpreadPilotVault.CircuitBreakerActive.selector);
        vault.executeSpreadSlice(
            orderId, address(adapter), 2_000e18, 1_990e18, 35, plan.estimatedBpsSaved, keccak256("demo-s3-blocked")
        );

        assertEq(vault.getOrder(orderId).slicesExecuted, 2);
        assertEq(vault.getOrder(orderId).remainingAmountIn, 1_000e6);
        assertEq(vault.getStats().totalRefusalsLogged, 1);
    }
}

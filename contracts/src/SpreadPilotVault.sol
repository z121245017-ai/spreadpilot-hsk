// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "./interfaces/IERC20.sol";
import {ISwapRouter02} from "./interfaces/ISwapRouter02.sol";
import {FullMath} from "./libraries/FullMath.sol";
import {SpreadPilotTypes} from "./SpreadPilotTypes.sol";

/// @title SpreadPilotVault
/// @notice Non-custodial user-owned execution vault with on-chain conversational policy enforcement,
///         liquidity-aware TWAP spread slicing, verifiable refusal proofs, and automatic stop-loss circuit breaker.
contract SpreadPilotVault {
    uint256 public constant MAX_ACTIVE_ORDERS = 10;
    uint16 public constant MAX_SLICES_PER_ORDER = 100;
    uint16 public constant MAX_POLICY_SLIPPAGE_BPS = 2_000; // 20.00% hard protocol ceiling
    uint16 public constant MAX_POLICY_DRAWDOWN_BPS = 5_000; // 50.00% hard protocol ceiling

    uint8 public constant BREAKER_REASON_DAILY_LOSS = 1;
    uint8 public constant BREAKER_REASON_STOP_LOSS_DRAWDOWN = 2;

    address public owner;
    address public immutable quoteToken;
    uint8 public immutable quoteDecimals;

    address public authorizedAgent;
    bool public circuitBreakerTripped;
    bytes32 public lastChatIntentHash;
    uint256 public policyVersion;
    uint256 public nextOrderId = 1;
    uint256 public activeOrderCount;

    SpreadPilotTypes.ExecutionPolicy public policy;
    SpreadPilotTypes.PositionStats public stats;

    mapping(address => bool) public allowedTokens;
    mapping(address => bool) public allowedRouters;
    mapping(uint256 => SpreadPilotTypes.TwapOrder) public orders;

    uint256 private _locked = 1;

    struct SliceExecContext {
        address tokenIn;
        address tokenOut;
        uint24 poolFee;
        uint256 sliceIn;
        uint256 sliceNotionalQuote;
        uint16 effectiveMaxSlippage;
        uint256 balOutBefore;
        uint256 actualOut;
        int256 sliceDeltaQuote;
    }

    // ────────────────────────── Events ──────────────────────────

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event Deposited(address indexed token, address indexed from, uint256 amount);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);
    event AgentAuthorized(address indexed agent, uint64 expiry);
    event AllowedTokenUpdated(address indexed token, bool allowed);
    event AllowedRouterUpdated(address indexed router, bool allowed);
    event RiskPresetApplied(
        SpreadPilotTypes.RiskAppetite indexed appetite,
        uint256 indexed policyVersion,
        SpreadPilotTypes.ExecutionPolicy policy
    );
    event PolicyUpdated(
        uint256 indexed policyVersion, bytes32 indexed chatIntentHash, SpreadPilotTypes.ExecutionPolicy policy
    );
    event EmergencyPaused(address indexed caller);
    event Unpaused(address indexed caller);
    event CircuitBreakerTripped(uint8 indexed reasonCode, uint256 observedValue, uint256 threshold, uint64 timestamp);
    event CircuitBreakerReset(address indexed caller, uint256 newHighWaterMarkQuote);
    event HighWaterMarkUpdated(uint256 previousHwm, uint256 newHwm);

    event TwapPlanCreated(
        uint256 indexed orderId,
        address indexed tokenIn,
        address indexed tokenOut,
        uint24 poolFee,
        uint256 totalAmountIn,
        uint256 sliceSize,
        uint16 slicesTotal,
        int32 minNetEdgeBps,
        uint16 maxSlippageBps,
        uint256 referencePrice1e8
    );
    event TwapPlanCancelled(uint256 indexed orderId, address indexed caller, uint256 remainingAmountIn);
    event SliceExecuted(
        uint256 indexed orderId,
        uint16 indexed sliceIndex,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        int32 observedNetEdgeBps,
        uint16 estimatedImpactSavedBps,
        int256 realizedDeltaQuote,
        bytes32 indexed decisionHash
    );
    event OpportunityRefused(
        address indexed caller,
        address indexed tokenIn,
        address indexed tokenOut,
        int32 observedEdgeBps,
        uint8 reasonCode,
        bytes32 decisionHash,
        uint64 timestamp
    );
    event MarkToMarketReported(
        uint256 portfolioValueQuote, uint256 highWaterMarkQuote, uint256 drawdownBps, bool tripped
    );

    // ────────────────────────── Errors ──────────────────────────

    error ZeroAddress();
    error ZeroAmount();
    error NotOwner();
    error NotAuthorized();
    error AgentExpired(uint64 expiry, uint256 currentTime);
    error Reentrancy();
    error VaultPaused();
    error CircuitBreakerActive();
    error TokenNotAllowed(address token);
    error RouterNotAllowed(address router);
    error IdenticalTokens();
    error InvalidPolicy(string reason);
    error InvalidSliceCount(uint16 slicesTotal);
    error MaxActiveOrdersReached();
    error MissingReferencePrice();
    error ExceedsMaxTotalNotional(uint256 notional, uint256 cap);
    error ExceedsMaxSliceNotional(uint256 notional, uint256 cap);
    error OrderEdgeLooserThanPolicy(int32 orderEdge, int32 policyEdge);
    error OrderSlippageLooserThanPolicy(uint16 orderSlippage, uint16 policySlippage);
    error OrderNotActive(uint256 orderId);
    error SliceCooldownActive(uint256 nextAllowedAt);
    error DailyTradeLimitReached(uint16 tradesToday, uint16 maxDailyTrades);
    error InsufficientNetEdge(int32 observedEdgeBps, int32 requiredEdgeBps);
    error InvalidExpectedOutput();
    error InsufficientVaultBalance(address token, uint256 available, uint256 required);
    error SlippageExceeded(uint256 actualOut, uint256 minAmountOut);
    error MaxSlippageExceeded(uint256 realizedSlippageBps, uint16 maxSlippageBps);
    error SafeTransferFailed(address token);

    // ────────────────────────── Modifiers ──────────────────────────

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyAgentOrOwner() {
        if (msg.sender != owner) {
            if (msg.sender == address(0) || msg.sender != authorizedAgent) {
                revert NotAuthorized();
            }
            if (block.timestamp > policy.agentExpiry) {
                revert AgentExpired(policy.agentExpiry, block.timestamp);
            }
        }
        _;
    }

    modifier whenOperational() {
        if (policy.paused) revert VaultPaused();
        if (circuitBreakerTripped) revert CircuitBreakerActive();
        _;
    }

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    // ────────────────────────── Constructor ──────────────────────────

    constructor(address initialOwner, address _quoteToken) {
        if (initialOwner == address(0) || _quoteToken == address(0)) revert ZeroAddress();

        owner = initialOwner;
        quoteToken = _quoteToken;
        quoteDecimals = _queryDecimals(_quoteToken);

        allowedTokens[_quoteToken] = true;
        stats.lastDayEpoch = uint64(block.timestamp / 1 days);

        _applyRiskPreset(SpreadPilotTypes.RiskAppetite.BALANCED);
    }

    // ────────────────────────── Custody & Governance ──────────────────────────

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        address prev = owner;
        owner = newOwner;
        emit OwnershipTransferred(prev, newOwner);
    }

    /// @notice Deposit allowed ERC-20 tokens into the user-owned vault.
    function deposit(address token, uint256 amount) external onlyOwner nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (!allowedTokens[token]) revert TokenNotAllowed(token);

        uint256 balBefore = IERC20(token).balanceOf(address(this));
        _safeTransferFrom(token, msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - balBefore;

        if (token == quoteToken) {
            stats.highWaterMarkQuote += received;
        }

        emit Deposited(token, msg.sender, received);
    }

    /// @notice Non-custodial withdraw; ALWAYS available to owner even when paused or breaker is tripped.
    function withdraw(address token, uint256 amount, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        _safeTransfer(token, to, amount);

        if (token == quoteToken) {
            stats.highWaterMarkQuote = amount >= stats.highWaterMarkQuote ? 0 : stats.highWaterMarkQuote - amount;
        }

        emit Withdrawn(token, to, amount);
    }

    function setAuthorizedAgent(address agent, uint64 expiry) external onlyOwner {
        authorizedAgent = agent;
        policy.agentExpiry = expiry;
        emit AgentAuthorized(agent, expiry);
    }

    function setAllowedToken(address token, bool allowed) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        allowedTokens[token] = allowed;
        emit AllowedTokenUpdated(token, allowed);
    }

    function setAllowedRouter(address router, bool allowed) external onlyOwner {
        if (router == address(0)) revert ZeroAddress();
        allowedRouters[router] = allowed;
        emit AllowedRouterUpdated(router, allowed);
    }

    /// @notice Applies conservative, balanced, or aggressive guardrail preset scaled to quoteToken decimals.
    function applyRiskPreset(SpreadPilotTypes.RiskAppetite appetite) external onlyOwner {
        _applyRiskPreset(appetite);
    }

    /// @notice Updates execution policy from natural-language chat intent, recording chatIntentHash on-chain.
    function updatePolicy(SpreadPilotTypes.ExecutionPolicy calldata newPolicy, bytes32 chatIntentHash)
        external
        onlyOwner
    {
        if (newPolicy.maxSliceNotional == 0) revert InvalidPolicy("maxSliceNotional=0");
        if (newPolicy.maxTotalOrderNotional < newPolicy.maxSliceNotional) {
            revert InvalidPolicy("maxTotal<maxSlice");
        }
        if (newPolicy.maxSlippageBps > MAX_POLICY_SLIPPAGE_BPS) revert InvalidPolicy("maxSlippage>2000");
        if (newPolicy.stopLossDrawdownBps == 0 || newPolicy.stopLossDrawdownBps > MAX_POLICY_DRAWDOWN_BPS) {
            revert InvalidPolicy("invalidStopLoss");
        }
        if (newPolicy.maxDailyTrades == 0) revert InvalidPolicy("maxDailyTrades=0");

        policy = newPolicy;
        lastChatIntentHash = chatIntentHash;
        policyVersion += 1;

        emit PolicyUpdated(policyVersion, chatIntentHash, newPolicy);
    }

    function emergencyPause() external onlyOwner {
        policy.paused = true;
        emit EmergencyPaused(msg.sender);
    }

    function unpause() external onlyOwner {
        policy.paused = false;
        emit Unpaused(msg.sender);
    }

    /// @notice Owner-only reset of tripped stop-loss / daily-loss circuit breaker.
    function resetCircuitBreaker() external onlyOwner {
        circuitBreakerTripped = false;
        stats.dailyLossQuote = 0;
        stats.lastDayEpoch = uint64(block.timestamp / 1 days);
        stats.highWaterMarkQuote = IERC20(quoteToken).balanceOf(address(this));

        emit CircuitBreakerReset(msg.sender, stats.highWaterMarkQuote);
    }

    /// @notice Allows owner to explicitly anchor multi-asset portfolio high-water mark in quote units.
    function setHighWaterMark(uint256 newHighWaterMarkQuote) external onlyOwner {
        uint256 prev = stats.highWaterMarkQuote;
        stats.highWaterMarkQuote = newHighWaterMarkQuote;
        emit HighWaterMarkUpdated(prev, newHighWaterMarkQuote);
    }

    // ────────────────────────── TWAP & Spread Execution ──────────────────────────

    function createTwapPlan(
        address tokenIn,
        address tokenOut,
        uint24 poolFee,
        uint256 totalAmountIn,
        uint16 slicesTotal,
        int32 minNetEdgeBps,
        uint16 maxSlippageBps,
        uint256 referencePrice1e8
    ) external onlyAgentOrOwner whenOperational returns (uint256 orderId) {
        if (tokenIn == tokenOut) revert IdenticalTokens();
        if (!allowedTokens[tokenIn]) revert TokenNotAllowed(tokenIn);
        if (!allowedTokens[tokenOut]) revert TokenNotAllowed(tokenOut);
        if (totalAmountIn == 0) revert ZeroAmount();
        if (slicesTotal == 0 || slicesTotal > MAX_SLICES_PER_ORDER) revert InvalidSliceCount(slicesTotal);
        if (activeOrderCount >= MAX_ACTIVE_ORDERS) revert MaxActiveOrdersReached();

        uint256 totalNotional = _toQuoteNotional(tokenIn, totalAmountIn, referencePrice1e8);
        if (totalNotional > policy.maxTotalOrderNotional) {
            revert ExceedsMaxTotalNotional(totalNotional, policy.maxTotalOrderNotional);
        }

        uint256 sliceSize = ((totalAmountIn - 1) / uint256(slicesTotal)) + 1;
        uint256 sliceNotional = _toQuoteNotional(tokenIn, sliceSize, referencePrice1e8);
        if (sliceNotional > policy.maxSliceNotional) {
            revert ExceedsMaxSliceNotional(sliceNotional, policy.maxSliceNotional);
        }

        uint256 available = IERC20(tokenIn).balanceOf(address(this));
        if (available < totalAmountIn) {
            revert InsufficientVaultBalance(tokenIn, available, totalAmountIn);
        }

        if (minNetEdgeBps < policy.minNetEdgeBps) {
            revert OrderEdgeLooserThanPolicy(minNetEdgeBps, policy.minNetEdgeBps);
        }

        uint16 effectiveOrderMaxSlippage = maxSlippageBps == 0 ? policy.maxSlippageBps : maxSlippageBps;
        if (effectiveOrderMaxSlippage > policy.maxSlippageBps) {
            revert OrderSlippageLooserThanPolicy(effectiveOrderMaxSlippage, policy.maxSlippageBps);
        }

        orderId = nextOrderId++;
        activeOrderCount += 1;

        orders[orderId] = SpreadPilotTypes.TwapOrder({
            orderId: orderId,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            poolFee: poolFee,
            totalAmountIn: totalAmountIn,
            remainingAmountIn: totalAmountIn,
            sliceSize: sliceSize,
            slicesTotal: slicesTotal,
            slicesExecuted: 0,
            minNetEdgeBps: minNetEdgeBps,
            maxSlippageBps: effectiveOrderMaxSlippage,
            referencePrice1e8: referencePrice1e8,
            createdAt: uint64(block.timestamp),
            lastSliceAt: 0,
            active: true,
            cancelled: false
        });

        emit TwapPlanCreated(
            orderId,
            tokenIn,
            tokenOut,
            poolFee,
            totalAmountIn,
            sliceSize,
            slicesTotal,
            minNetEdgeBps,
            effectiveOrderMaxSlippage,
            referencePrice1e8
        );
    }

    function executeSpreadSlice(
        uint256 orderId,
        address router,
        uint256 expectedOutAtRef,
        uint256 minAmountOut,
        int32 observedNetEdgeBps,
        uint16 estimatedImpactSavedBps,
        bytes32 decisionHash
    ) external nonReentrant onlyAgentOrOwner whenOperational returns (uint256 actualOut) {
        if (!allowedRouters[router]) revert RouterNotAllowed(router);
        if (expectedOutAtRef == 0) revert InvalidExpectedOutput();

        SpreadPilotTypes.TwapOrder storage order = orders[orderId];
        if (!order.active || order.remainingAmountIn == 0) revert OrderNotActive(orderId);

        SliceExecContext memory ctx;
        ctx.tokenIn = order.tokenIn;
        ctx.tokenOut = order.tokenOut;
        ctx.poolFee = order.poolFee;

        if (!allowedTokens[ctx.tokenIn]) revert TokenNotAllowed(ctx.tokenIn);
        if (!allowedTokens[ctx.tokenOut]) revert TokenNotAllowed(ctx.tokenOut);

        if (order.lastSliceAt != 0) {
            uint256 nextAllowedAt = uint256(order.lastSliceAt) + uint256(policy.minSliceIntervalSec);
            if (block.timestamp < nextAllowedAt) {
                revert SliceCooldownActive(nextAllowedAt);
            }
        }

        _rollDailyStatsIfNeeded();
        if (stats.tradesToday >= policy.maxDailyTrades) {
            revert DailyTradeLimitReached(stats.tradesToday, policy.maxDailyTrades);
        }

        int32 requiredEdge = order.minNetEdgeBps > policy.minNetEdgeBps ? order.minNetEdgeBps : policy.minNetEdgeBps;
        if (observedNetEdgeBps < requiredEdge) {
            revert InsufficientNetEdge(observedNetEdgeBps, requiredEdge);
        }

        ctx.sliceIn = order.remainingAmountIn < order.sliceSize ? order.remainingAmountIn : order.sliceSize;
        ctx.sliceNotionalQuote = _toQuoteNotional(ctx.tokenIn, ctx.sliceIn, order.referencePrice1e8);
        if (ctx.sliceNotionalQuote > policy.maxSliceNotional) {
            revert ExceedsMaxSliceNotional(ctx.sliceNotionalQuote, policy.maxSliceNotional);
        }

        ctx.effectiveMaxSlippage =
            order.maxSlippageBps < policy.maxSlippageBps ? order.maxSlippageBps : policy.maxSlippageBps;

        uint256 balInBefore = IERC20(ctx.tokenIn).balanceOf(address(this));
        if (balInBefore < ctx.sliceIn) {
            revert InsufficientVaultBalance(ctx.tokenIn, balInBefore, ctx.sliceIn);
        }
        ctx.balOutBefore = IERC20(ctx.tokenOut).balanceOf(address(this));

        _safeApprove(ctx.tokenIn, router, 0);
        _safeApprove(ctx.tokenIn, router, ctx.sliceIn);

        ISwapRouter02(router).exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: ctx.tokenIn,
                tokenOut: ctx.tokenOut,
                fee: ctx.poolFee,
                recipient: address(this),
                amountIn: ctx.sliceIn,
                amountOutMinimum: minAmountOut,
                sqrtPriceLimitX96: 0
            })
        );

        _safeApprove(ctx.tokenIn, router, 0);

        uint256 balOutAfter = IERC20(ctx.tokenOut).balanceOf(address(this));
        ctx.actualOut = balOutAfter - ctx.balOutBefore;
        if (ctx.actualOut < minAmountOut) {
            revert SlippageExceeded(ctx.actualOut, minAmountOut);
        }

        if (ctx.actualOut < expectedOutAtRef) {
            uint256 realizedSlippageBps =
                FullMath.mulDiv(expectedOutAtRef - ctx.actualOut, SpreadPilotTypes.BPS_DENOMINATOR, expectedOutAtRef);
            if (realizedSlippageBps > ctx.effectiveMaxSlippage) {
                revert MaxSlippageExceeded(realizedSlippageBps, ctx.effectiveMaxSlippage);
            }
        }

        // Update TWAP order progress
        order.remainingAmountIn -= ctx.sliceIn;
        order.slicesExecuted += 1;
        order.lastSliceAt = uint64(block.timestamp);
        if (order.remainingAmountIn == 0 || order.slicesExecuted >= order.slicesTotal) {
            order.active = false;
            activeOrderCount -= 1;
        }

        // Compute quote-denominated execution delta vs reference expectation
        ctx.sliceDeltaQuote = _computeSliceDeltaQuote(ctx, expectedOutAtRef);

        stats.totalVolumeIn += ctx.sliceIn;
        stats.totalVolumeOut += ctx.actualOut;
        stats.tradesToday += 1;
        stats.totalSlicesExecuted += 1;
        stats.cumulativeSlippageSavedBps += uint256(estimatedImpactSavedBps);
        stats.realizedPnlQuote += ctx.sliceDeltaQuote;

        if (ctx.sliceDeltaQuote < 0) {
            stats.dailyLossQuote += uint256(-ctx.sliceDeltaQuote);
        } else if (ctx.tokenOut == quoteToken) {
            uint256 currentQuoteBal = IERC20(quoteToken).balanceOf(address(this));
            if (currentQuoteBal > stats.highWaterMarkQuote) {
                stats.highWaterMarkQuote = currentQuoteBal;
            }
        }

        emit SliceExecuted(
            orderId,
            order.slicesExecuted,
            ctx.tokenIn,
            ctx.tokenOut,
            ctx.sliceIn,
            ctx.actualOut,
            observedNetEdgeBps,
            estimatedImpactSavedBps,
            ctx.sliceDeltaQuote,
            decisionHash
        );

        _checkPostExecutionCircuitBreaker();

        return ctx.actualOut;
    }

    /// @notice Writes verifiable on-chain refusal proof without moving any funds.
    function logRefusedOpportunity(
        address tokenIn,
        address tokenOut,
        int32 observedEdgeBps,
        uint8 reasonCode,
        bytes32 decisionHash
    ) external onlyAgentOrOwner {
        stats.totalRefusalsLogged += 1;
        emit OpportunityRefused(
            msg.sender, tokenIn, tokenOut, observedEdgeBps, reasonCode, decisionHash, uint64(block.timestamp)
        );
    }

    /// @notice Cancels an active TWAP order; callable by owner or agent even when paused or breaker is active.
    function cancelTwapPlan(uint256 orderId) external onlyAgentOrOwner {
        SpreadPilotTypes.TwapOrder storage order = orders[orderId];
        if (!order.active) revert OrderNotActive(orderId);

        order.active = false;
        order.cancelled = true;
        activeOrderCount -= 1;

        emit TwapPlanCancelled(orderId, msg.sender, order.remainingAmountIn);
    }

    /// @notice Evaluates mark-to-market portfolio equity against highWaterMarkQuote and trips
    ///         the stop-loss circuit breaker when drawdown >= policy.stopLossDrawdownBps.
    function reportMarkToMarketAndCheckStopLoss(uint256 currentPortfolioValueQuote)
        external
        onlyAgentOrOwner
        returns (bool tripped)
    {
        if (currentPortfolioValueQuote >= stats.highWaterMarkQuote) {
            stats.highWaterMarkQuote = currentPortfolioValueQuote;
            emit MarkToMarketReported(currentPortfolioValueQuote, stats.highWaterMarkQuote, 0, false);
            return false;
        }

        uint256 drawdownAmount = stats.highWaterMarkQuote - currentPortfolioValueQuote;
        uint256 drawdownBps =
            FullMath.mulDiv(drawdownAmount, SpreadPilotTypes.BPS_DENOMINATOR, stats.highWaterMarkQuote);

        if (drawdownBps >= policy.stopLossDrawdownBps) {
            circuitBreakerTripped = true;
            tripped = true;
            emit MarkToMarketReported(currentPortfolioValueQuote, stats.highWaterMarkQuote, drawdownBps, true);
            emit CircuitBreakerTripped(
                BREAKER_REASON_STOP_LOSS_DRAWDOWN, drawdownBps, policy.stopLossDrawdownBps, uint64(block.timestamp)
            );
            return true;
        }

        emit MarkToMarketReported(currentPortfolioValueQuote, stats.highWaterMarkQuote, drawdownBps, false);
        return false;
    }

    // ────────────────────────── Frontend Views ──────────────────────────

    function getPolicy() external view returns (SpreadPilotTypes.ExecutionPolicy memory) {
        return policy;
    }

    function getStats() external view returns (SpreadPilotTypes.PositionStats memory) {
        return stats;
    }

    function getOrder(uint256 orderId) external view returns (SpreadPilotTypes.TwapOrder memory) {
        return orders[orderId];
    }

    function isAgentActive() external view returns (bool) {
        return authorizedAgent != address(0) && block.timestamp <= policy.agentExpiry && !policy.paused
            && !circuitBreakerTripped;
    }

    function getVaultSummary()
        external
        view
        returns (
            address vaultOwner,
            address agent,
            address quote,
            bool breakerTripped,
            uint256 version,
            bytes32 chatHash,
            uint256 activeOrders,
            uint256 nextId
        )
    {
        return (
            owner,
            authorizedAgent,
            quoteToken,
            circuitBreakerTripped,
            policyVersion,
            lastChatIntentHash,
            activeOrderCount,
            nextOrderId
        );
    }

    // ────────────────────────── Internals ──────────────────────────

    function _applyRiskPreset(SpreadPilotTypes.RiskAppetite appetite) internal {
        uint256 unit = 10 ** uint256(quoteDecimals);
        uint64 prevExpiry = policy.agentExpiry;
        bool prevPaused = policy.paused;

        if (appetite == SpreadPilotTypes.RiskAppetite.CONSERVATIVE) {
            policy = SpreadPilotTypes.ExecutionPolicy({
                maxSliceNotional: 500 * unit,
                maxTotalOrderNotional: 2_000 * unit,
                minSliceIntervalSec: 120,
                minNetEdgeBps: 25,
                maxSlippageBps: 30,
                stopLossDrawdownBps: 200,
                dailyLossLimit: 250 * unit,
                maxDailyTrades: 12,
                agentExpiry: prevExpiry,
                paused: prevPaused,
                riskAppetite: appetite
            });
        } else if (appetite == SpreadPilotTypes.RiskAppetite.BALANCED) {
            policy = SpreadPilotTypes.ExecutionPolicy({
                maxSliceNotional: 1_500 * unit,
                maxTotalOrderNotional: 10_000 * unit,
                minSliceIntervalSec: 45,
                minNetEdgeBps: 15,
                maxSlippageBps: 60,
                stopLossDrawdownBps: 500,
                dailyLossLimit: 1_000 * unit,
                maxDailyTrades: 30,
                agentExpiry: prevExpiry,
                paused: prevPaused,
                riskAppetite: appetite
            });
        } else {
            policy = SpreadPilotTypes.ExecutionPolicy({
                maxSliceNotional: 5_000 * unit,
                maxTotalOrderNotional: 25_000 * unit,
                minSliceIntervalSec: 15,
                minNetEdgeBps: 8,
                maxSlippageBps: 120,
                stopLossDrawdownBps: 1_000,
                dailyLossLimit: 3_000 * unit,
                maxDailyTrades: 60,
                agentExpiry: prevExpiry,
                paused: prevPaused,
                riskAppetite: appetite
            });
        }

        policyVersion += 1;
        emit RiskPresetApplied(appetite, policyVersion, policy);
    }

    function _rollDailyStatsIfNeeded() internal {
        uint64 today = uint64(block.timestamp / 1 days);
        if (today != stats.lastDayEpoch) {
            stats.tradesToday = 0;
            stats.dailyLossQuote = 0;
            stats.lastDayEpoch = today;
        }
    }

    function _computeSliceDeltaQuote(SliceExecContext memory ctx, uint256 expectedOutAtRef)
        internal
        view
        returns (int256)
    {
        if (ctx.tokenOut == quoteToken) {
            return ctx.actualOut >= expectedOutAtRef
                ? int256(ctx.actualOut - expectedOutAtRef)
                : -int256(expectedOutAtRef - ctx.actualOut);
        }

        if (ctx.actualOut >= expectedOutAtRef) {
            uint256 gainQuote = FullMath.mulDiv(ctx.actualOut - expectedOutAtRef, ctx.sliceNotionalQuote, expectedOutAtRef);
            return int256(gainQuote);
        } else {
            uint256 lossQuote = FullMath.mulDiv(expectedOutAtRef - ctx.actualOut, ctx.sliceNotionalQuote, expectedOutAtRef);
            return -int256(lossQuote);
        }
    }

    function _checkPostExecutionCircuitBreaker() internal {
        if (policy.dailyLossLimit > 0 && stats.dailyLossQuote >= policy.dailyLossLimit) {
            circuitBreakerTripped = true;
            emit CircuitBreakerTripped(
                BREAKER_REASON_DAILY_LOSS, stats.dailyLossQuote, policy.dailyLossLimit, uint64(block.timestamp)
            );
            return;
        }

        if (stats.highWaterMarkQuote > 0 && stats.realizedPnlQuote < 0) {
            uint256 drawdownBps = FullMath.mulDiv(
                uint256(-stats.realizedPnlQuote), SpreadPilotTypes.BPS_DENOMINATOR, stats.highWaterMarkQuote
            );
            if (drawdownBps >= policy.stopLossDrawdownBps) {
                circuitBreakerTripped = true;
                emit CircuitBreakerTripped(
                    BREAKER_REASON_STOP_LOSS_DRAWDOWN,
                    drawdownBps,
                    policy.stopLossDrawdownBps,
                    uint64(block.timestamp)
                );
            }
        }
    }

    function _toQuoteNotional(address tokenIn, uint256 amountIn, uint256 referencePrice1e8)
        internal
        view
        returns (uint256 notional)
    {
        if (tokenIn == quoteToken) {
            return amountIn;
        }
        if (referencePrice1e8 == 0) revert MissingReferencePrice();

        uint8 decIn = _queryDecimals(tokenIn);
        uint256 scaledInTokenDecimals = FullMath.mulDiv(amountIn, referencePrice1e8, SpreadPilotTypes.PRICE_SCALE);

        if (decIn == quoteDecimals) {
            notional = scaledInTokenDecimals;
        } else if (decIn > quoteDecimals) {
            notional = scaledInTokenDecimals / (10 ** uint256(decIn - quoteDecimals));
        } else {
            notional = scaledInTokenDecimals * (10 ** uint256(quoteDecimals - decIn));
        }

        if (amountIn > 0 && notional == 0) {
            notional = 1;
        }
    }

    function _queryDecimals(address token) internal view returns (uint8) {
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSelector(IERC20.decimals.selector));
        if (ok && data.length >= 32) {
            uint8 dec = abi.decode(data, (uint8));
            if (dec <= 30) return dec;
        }
        return 18;
    }

    function _safeTransfer(address token, address to, uint256 value) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, value));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) {
            revert SafeTransferFailed(token);
        }
    }

    function _safeTransferFrom(address token, address from, address to, uint256 value) internal {
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, value));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) {
            revert SafeTransferFailed(token);
        }
    }

    function _safeApprove(address token, address spender, uint256 value) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.approve.selector, spender, value));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) {
            revert SafeTransferFailed(token);
        }
    }
}

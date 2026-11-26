// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "./interfaces/IERC20.sol";
import {ISwapRouter02} from "./interfaces/ISwapRouter02.sol";
import {IHSKSwapV3Pool} from "./interfaces/IHSKSwapV3Pool.sol";
import {FullMath} from "./libraries/FullMath.sol";

/// @title TestnetV3Pool
/// @notice Minimal IHSKSwapV3Pool mirror for HSK Chain Testnet (133) so HSKSwapLiquidityLens
///         can inspect live on-chain sqrtPriceX96 and active liquidity just like on Mainnet (177).
contract TestnetV3Pool is IHSKSwapV3Pool {
    address public owner;
    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;

    uint160 private _sqrtPriceX96;
    int24 private _tick;
    uint128 private _liquidity;

    event PoolStateUpdated(uint160 sqrtPriceX96, int24 tick, uint128 liquidity);

    error NotOwner();

    constructor(
        address _token0,
        address _token1,
        uint24 _fee,
        uint160 initialSqrtPriceX96,
        int24 initialTick,
        uint128 initialLiquidity
    ) {
        owner = msg.sender;
        token0 = _token0;
        token1 = _token1;
        fee = _fee;
        _sqrtPriceX96 = initialSqrtPriceX96;
        _tick = initialTick;
        _liquidity = initialLiquidity;
    }

    function updateState(uint160 newSqrtPriceX96, int24 newTick, uint128 newLiquidity) external {
        if (msg.sender != owner) revert NotOwner();
        _sqrtPriceX96 = newSqrtPriceX96;
        _tick = newTick;
        _liquidity = newLiquidity;
        emit PoolStateUpdated(newSqrtPriceX96, newTick, newLiquidity);
    }

    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        )
    {
        return (_sqrtPriceX96, _tick, 0, 1, 1, 0, true);
    }

    function liquidity() external view returns (uint128) {
        return _liquidity;
    }
}

/// @title TestnetHSKSwapAdapter
/// @notice Lightweight ISwapRouter02-compatible AMM adapter for HSK Chain Testnet (133).
///         Models pool fee, virtual V3 depth price impact, and configurable spread shifts so
///         judges can verify profitable spread slices, TWAP slippage savings, and stop-loss trips live.
contract TestnetHSKSwapAdapter is ISwapRouter02 {
    uint256 public constant RATE_SCALE = 1e18;
    uint256 public constant FEE_DENOMINATOR = 1_000_000;
    uint256 public constant BPS_DENOMINATOR = 10_000;

    struct PairConfig {
        uint256 rate1e18; // raw tokenOut units per 1e18 raw tokenIn units
        uint128 virtualLiquidity; // active depth in tokenIn raw units (0 = no simulated impact)
        int16 spreadBonusBps; // signed venue spread adjustment in bps
        bool enabled;
    }

    address public owner;
    mapping(bytes32 => PairConfig) public pairConfigs;

    event PairConfigured(
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 rate1e18,
        uint128 virtualLiquidity,
        int16 spreadBonusBps
    );
    event AdapterSwapExecuted(
        address indexed sender,
        address indexed recipient,
        address indexed tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint256 amountOut,
        uint16 simulatedImpactBps
    );

    error NotOwner();
    error PairNotConfigured(address tokenIn, address tokenOut);
    error InvalidFee(uint24 fee);
    error InsufficientOutput(uint256 amountOut, uint256 amountOutMinimum);
    error InsufficientAdapterReserves(address tokenOut, uint256 available, uint256 required);
    error TransferFailed(address token);

    constructor() {
        owner = msg.sender;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    function pairKey(address tokenIn, address tokenOut) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(tokenIn, tokenOut));
    }

    function setPairConfig(
        address tokenIn,
        address tokenOut,
        uint256 rate1e18,
        uint128 virtualLiquidity,
        int16 spreadBonusBps
    ) external onlyOwner {
        pairConfigs[pairKey(tokenIn, tokenOut)] = PairConfig({
            rate1e18: rate1e18,
            virtualLiquidity: virtualLiquidity,
            spreadBonusBps: spreadBonusBps,
            enabled: true
        });
        emit PairConfigured(tokenIn, tokenOut, rate1e18, virtualLiquidity, spreadBonusBps);
    }

    function quoteExactInputSingle(address tokenIn, address tokenOut, uint24 fee, uint256 amountIn)
        public
        view
        returns (uint256 amountOut, uint16 impactBps)
    {
        PairConfig memory cfg = pairConfigs[pairKey(tokenIn, tokenOut)];
        if (!cfg.enabled) revert PairNotConfigured(tokenIn, tokenOut);
        if (fee >= FEE_DENOMINATOR) revert InvalidFee(fee);
        if (amountIn == 0) return (0, 0);

        uint256 baseOut = FullMath.mulDiv(amountIn, cfg.rate1e18, RATE_SCALE);
        uint256 afterFee = FullMath.mulDiv(baseOut, FEE_DENOMINATOR - uint256(fee), FEE_DENOMINATOR);

        if (cfg.virtualLiquidity > 0) {
            uint256 liq = uint256(cfg.virtualLiquidity);
            uint256 rawImpact = amountIn >= liq * BPS_DENOMINATOR
                ? 9_999
                : FullMath.mulDivRoundingUp(amountIn, BPS_DENOMINATOR, liq + amountIn);
            impactBps = rawImpact > 9_999 ? 9_999 : uint16(rawImpact);
        }

        int256 netMultiplier = int256(BPS_DENOMINATOR) - int256(uint256(impactBps)) + int256(cfg.spreadBonusBps);
        if (netMultiplier < 1) {
            netMultiplier = 1;
        }

        amountOut = FullMath.mulDiv(afterFee, uint256(netMultiplier), BPS_DENOMINATOR);
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut)
    {
        uint16 impactBps;
        (amountOut, impactBps) = quoteExactInputSingle(params.tokenIn, params.tokenOut, params.fee, params.amountIn);

        if (amountOut < params.amountOutMinimum) {
            revert InsufficientOutput(amountOut, params.amountOutMinimum);
        }

        uint256 available = IERC20(params.tokenOut).balanceOf(address(this));
        if (available < amountOut) {
            revert InsufficientAdapterReserves(params.tokenOut, available, amountOut);
        }

        _safeTransferFrom(params.tokenIn, msg.sender, address(this), params.amountIn);
        _safeTransfer(params.tokenOut, params.recipient, amountOut);

        emit AdapterSwapExecuted(
            msg.sender,
            params.recipient,
            params.tokenIn,
            params.tokenOut,
            params.fee,
            params.amountIn,
            amountOut,
            impactBps
        );
    }

    function withdrawReserves(address token, address to, uint256 amount) external onlyOwner {
        _safeTransfer(token, to, amount);
    }

    function _safeTransfer(address token, address to, uint256 value) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, value));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) {
            revert TransferFailed(token);
        }
    }

    function _safeTransferFrom(address token, address from, address to, uint256 value) internal {
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, value));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) {
            revert TransferFailed(token);
        }
    }
}

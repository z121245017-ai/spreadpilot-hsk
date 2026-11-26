// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title Minimal Uniswap V3 / HSKSwap V3 Pool read interface
/// @notice Compatible with live HSK Chain Mainnet WHSK/USDT pools
///         (0xEB33d6666dd2359cB1BF6Ea6D72286Cc1b4a778A and 0x0767F7b1af495D245EA00219cFB8B2Ed6EafAe62).
interface IHSKSwapV3Pool {
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
        );

    function liquidity() external view returns (uint128);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
}

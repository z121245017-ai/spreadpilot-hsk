// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "./IERC20.sol";

/// @title Minimal Uniswap V3 SwapRouter02 / HSKSwap Router interface
/// @notice Matches verified HSK Chain Testnet SwapRouter02 (0x46cBccE3c74E95d1761435d52B0b9Abc9e2FEAC0)
///         and TestnetHSKSwapAdapter exactInputSingle selector (0x04e45aaf).
interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

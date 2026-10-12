// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Aerodrome Router 0xcF77…4E43 (basic pools; defaultFactory 0x420D…40Da). Same function as funds-core's
///         IAerodromeRouter (selector 0x88cd821e): pulls `amountIn` into the first pool, swaps what arrived, and
///         reverts unless the recipient's balance of the last token rose by at least `amountOutMin`.
interface IAerodromeRouter {
	struct Route {
		address from;
		address to;
		bool stable;
		address factory;
	}

	function swapExactTokensForTokensSupportingFeeOnTransferTokens(
		uint256 amountIn,
		uint256 amountOutMin,
		Route[] calldata routes,
		address to,
		uint256 deadline
	) external;
}

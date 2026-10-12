// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice The one FrostyFi ValueInterpreter function the strategy uses (funds-core `ValueInterpreter`): the value of
///         `amount` of `baseAsset` in `quoteAsset` units, from oracle feeds; reverts on a stale or missing price.
interface IValueInterpreter {
	function calcCanonicalAssetValue(address baseAsset, uint256 amount, address quoteAsset) external view returns (uint256 value);
}

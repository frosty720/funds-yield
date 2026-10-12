// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

/// @notice Stands in for FrostyFi's ValueInterpreter in fork tests: the real VI's Chainlink feeds go stale as soon as a
///         test skips time. Values `amount` of `base` in `quote` at a set rate (quote units per 1e18 base units).
contract MockValueInterpreter {
	mapping(address base => mapping(address quote => uint256)) public rate;
	bool public reverting;

	error MockStalePrice();

	function setRate(address base, address quote, uint256 quotePerBaseUnit) external {
		rate[base][quote] = quotePerBaseUnit;
	}

	function setReverting(bool on) external {
		reverting = on;
	}

	function calcCanonicalAssetValue(address base, uint256 amount, address quote) external view returns (uint256) {
		if (reverting) revert MockStalePrice();
		return amount * rate[base][quote] / 1e18;
	}
}

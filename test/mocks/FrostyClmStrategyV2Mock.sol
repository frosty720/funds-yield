// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {FrostyClmStrategy} from '../../contracts/strategies/velodrome/FrostyClmStrategy.sol';

/// @notice A next implementation for the beacon-upgrade test: same storage, one extra function.
contract FrostyClmStrategyV2Mock is FrostyClmStrategy {
	function version() external pure returns (uint256) {
		return 2;
	}
}

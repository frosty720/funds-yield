// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Script, console2} from 'forge-std/Script.sol';
import {VmSafe} from 'forge-std/Vm.sol';
import {FrostyClmStrategyV2} from '../contracts/strategies/aero/FrostyClmStrategyV2.sol';
import {FrostyClmStrategyFactory} from '../contracts/strategies/FrostyClmStrategyFactory.sol';

/// @notice Points the CLM v2 beacon at the fee fix (red-team YIELD-02, 2026-10-27): every v2 strategy upgrades in place, same
///         addresses, same storage. Rehearsed in test/fork/UpgradeClmStrategyV2Fork.t.sol. Run by the factory's owner:
///         forge script script/UpgradeClmStrategyV2.s.sol --rpc-url base --account frosty-main --sender <deployer> --broadcast
contract UpgradeClmStrategyV2 is Script {
	string internal constant BOOK = 'deployments/base-mainnet-clm-v2.json';

	function run() external {
		string memory book = vm.readFile(BOOK);
		FrostyClmStrategyFactory factory = FrostyClmStrategyFactory(vm.parseJsonAddress(book, '.strategyFactory'));
		string memory name = vm.parseJsonString(book, '.strategyName');
		_requireNothingParkedOrLocked(book);
		vm.startBroadcast();
		address implementation = address(new FrostyClmStrategyV2());
		factory.upgradeTo(name, implementation);
		vm.stopBroadcast();
		console2.log('FrostyClmStrategyV2 implementation', implementation);
		// a dry run's simulated address must never reach the address book
		if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) vm.writeJson(vm.toString(implementation), BOOK, '.strategyImplementation');
	}

	/// @dev Run this before any funded harvest: fees already locked would keep ClmVaultPriceFeed deducting them (nothing
	///      clears totalLocked0/1 now), and parked ones would reach the share price all at once at the upgrade.
	function _requireNothingParkedOrLocked(string memory book) internal view {
		string[] memory symbols = vm.parseJsonKeys(book, '.vaults');
		for (uint256 i; i < symbols.length; ++i) {
			FrostyClmStrategyV2 strategy = FrostyClmStrategyV2(payable(vm.parseJsonAddress(book, string.concat('.vaults.', symbols[i], '.strategy'))));
			bool clean = strategy.fees0() == 0 && strategy.fees1() == 0 && strategy.totalLocked0() == 0 && strategy.totalLocked1() == 0;
			require(clean, string.concat(symbols[i], ': fees parked or locked, see this script'));
		}
	}
}

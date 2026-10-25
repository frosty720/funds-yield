// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Script, console} from 'forge-std/Script.sol';
import {ClmPoolDeployerV2} from '../contracts/deploy/ClmPoolDeployerV2.sol';
import {FrostyClmStrategyV2} from '../contracts/strategies/aero/FrostyClmStrategyV2.sol';
import {FrostyClmStrategyFactory} from '../contracts/strategies/FrostyClmStrategyFactory.sol';
import {FrostyClmVaultFactory} from '../contracts/vault/FrostyClmVaultFactory.sol';

/// @notice FrostyClmStrategyV2 on Aero (FrostyFi 2026-10-25), added to v1's strategy factory and vault factory
///         (deployments/base-mainnet-clm.json): the same treasury, 9.5% fee, keeper and rebalancers, and ClmVaultPriceFeed
///         prices its vaults as it does v1's (it checks the strategy's factory). Three steps, as DeployClm:
///         1. forge, by the strategy factory's owner (addStrategy is owner or keeper only):
///            forge script script/DeployClmV2.s.sol --rpc-url base --account frosty-main --sender <deployer> --broadcast
///              --slow --verify
///         2. cast, once per entry of script/config/base-mainnet-pools-v2.json (stock tokens are B20: only Base's own node
///            runs them): ~/FrostyFunds/.ops-scratch/deploy-clm-v2-pools.sh
///         3. forge, read-only: writes deployments/base-mainnet-clm-v2.json from the chain.
///            forge script script/DeployClmV2.s.sol --sig 'writeDeployments(address)' <ClmPoolDeployerV2> --rpc-url base
contract DeployClmV2 is Script {
	string public constant V1_PATH = 'deployments/base-mainnet-clm.json';
	string public constant POOLS_PATH = 'script/config/base-mainnet-pools-v2.json';
	string public constant OUTPUT_PATH = 'deployments/base-mainnet-clm-v2.json';

	function run() external {
		(FrostyClmStrategyFactory strategyFactory,) = v1Factories();
		vm.startBroadcast();
		(address implementation, ClmPoolDeployerV2 deployer) = deployCore(msg.sender);
		strategyFactory.addStrategy(deployer.STRATEGY_NAME(), implementation);
		vm.stopBroadcast();
		console.log('FrostyClmStrategyV2', implementation);
		console.log('ClmPoolDeployerV2', address(deployer));
	}

	/// @notice v1's strategy factory and vault factory.
	function v1Factories() public view returns (FrostyClmStrategyFactory strategyFactory, FrostyClmVaultFactory vaultFactory) {
		string memory json = vm.readFile(V1_PATH);
		strategyFactory = FrostyClmStrategyFactory(vm.parseJsonAddress(json, '.strategyFactory'));
		vaultFactory = FrostyClmVaultFactory(vm.parseJsonAddress(json, '.vaultFactory'));
	}

	function readPools() public view returns (ClmPoolDeployerV2.PoolConfig[] memory) {
		return abi.decode(vm.parseJson(vm.readFile(POOLS_PATH)), (ClmPoolDeployerV2.PoolConfig[]));
	}

	/// @notice The v2 implementation and a pool deployer owned by `owner`; the factory's owner then adds the
	///         implementation under the deployer's STRATEGY_NAME (run does, in the same broadcast).
	function deployCore(address owner) public returns (address implementation, ClmPoolDeployerV2 deployer) {
		(FrostyClmStrategyFactory strategyFactory, FrostyClmVaultFactory vaultFactory) = v1Factories();
		implementation = address(new FrostyClmStrategyV2());
		deployer = new ClmPoolDeployerV2(strategyFactory, vaultFactory, owner);
	}

	/// @notice Writes deployments/base-mainnet-clm-v2.json from what `deployer` recorded on chain.
	function writeDeployments(ClmPoolDeployerV2 deployer) external {
		FrostyClmStrategyFactory strategyFactory = deployer.strategyFactory();
		string memory vaultsJson;
		for (uint256 i; i < deployer.deploymentCount(); ++i) {
			vaultsJson = _vaultJson(deployer, i);
		}
		vm.serializeAddress('clm', 'strategyFactory', address(strategyFactory));
		vm.serializeAddress('clm', 'vaultFactory', address(deployer.vaultFactory()));
		vm.serializeAddress('clm', 'poolDeployer', address(deployer));
		vm.serializeAddress('clm', 'strategyImplementation', strategyFactory.getImplementation(deployer.STRATEGY_NAME()));
		vm.serializeString('clm', 'strategyName', deployer.STRATEGY_NAME());
		vm.writeJson(vm.serializeString('clm', 'vaults', vaultsJson), OUTPUT_PATH);
		console.log('wrote', OUTPUT_PATH);
	}

	/// @dev Adds deployment `i` to the 'vaults' object and returns that object so far (no gauge: v2 never stakes).
	function _vaultJson(ClmPoolDeployerV2 deployer, uint256 i) private returns (string memory) {
		(string memory symbol, address pool,, address strategy, address vault) = deployer.deployments(i);
		vm.serializeAddress(symbol, 'vault', vault);
		vm.serializeAddress(symbol, 'strategy', strategy);
		return vm.serializeString('vaults', symbol, vm.serializeAddress(symbol, 'pool', pool));
	}
}

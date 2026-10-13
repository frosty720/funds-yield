// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Script, console} from 'forge-std/Script.sol';
import {ClmPoolDeployer} from '../contracts/deploy/ClmPoolDeployer.sol';
import {FrostyClmStrategy} from '../contracts/strategies/velodrome/FrostyClmStrategy.sol';
import {FrostyClmStrategyFactory} from '../contracts/strategies/FrostyClmStrategyFactory.sol';
import {FrostyClmVaultFactory} from '../contracts/vault/FrostyClmVaultFactory.sol';

/// @notice Deploys FrostyFi's CLM on Base in three steps (final review C1, 2026-10-11). forge simulates every script
///         locally, and stock tokens (B20) only run on Base's own node, so nothing here touches a stock token.
///         1. forge: the strategy implementation behind a beacon, both factories and ClmPoolDeployer.
///            KEEPER_ADDRESS=<keeper Engine wallet> forge script script/DeployClm.s.sol --rpc-url base
///              --account frosty-main --sender <deployer> --broadcast --slow --verify
///         2. cast, once per entry of script/config/base-mainnet-pools.json (Beefy's live settings, 2026-10-11):
///            cast send <poolDeployer> 'deployPool((address,address,int56,address,int24,string,uint32))' '(<compoundToken>,
///              <gauge>,<maxTickDeviation>,<pool>,<positionWidth>,<symbol>,<twapInterval>)' --rpc-url base
///              --account frosty-main
///         3. forge, read-only: writes deployments/base-mainnet-clm.json from the chain.
///            forge script script/DeployClm.s.sol --sig 'writeDeployments(address)' <poolDeployer> --rpc-url base
contract DeployClm is Script {
	address public constant VALUE_INTERPRETER = 0x3CDbaBE5Bf4E6cfE10A2A326E0ad31b2d16398D4;
	address public constant TREASURY = 0x47b7702a4789912d0dfFDadC07c50395c293fF0A;
	uint256 public constant PERF_FEE_BPS = 950; // 9.5%, Beefy's total fee (founder 2026-10-11)
	string public constant POOLS_PATH = 'script/config/base-mainnet-pools.json';
	string public constant OUTPUT_PATH = 'deployments/base-mainnet-clm.json';

	function run() external {
		address keeper = vm.envAddress('KEEPER_ADDRESS');
		address rebalancer = vm.envOr('REBALANCER_ADDRESS', keeper);
		vm.startBroadcast();
		(,, ClmPoolDeployer deployer) = deployCore(keeper, rebalancer, msg.sender);
		vm.stopBroadcast();
		console.log('ClmPoolDeployer', address(deployer));
	}

	function readPools() public view returns (ClmPoolDeployer.PoolConfig[] memory) {
		return abi.decode(vm.parseJson(vm.readFile(POOLS_PATH)), (ClmPoolDeployer.PoolConfig[]));
	}

	function deployCore(address keeper, address rebalancer, address owner)
		public
		returns (FrostyClmStrategyFactory strategyFactory, FrostyClmVaultFactory vaultFactory, ClmPoolDeployer deployer)
	{
		strategyFactory = new FrostyClmStrategyFactory(keeper, TREASURY, VALUE_INTERPRETER, PERF_FEE_BPS);
		vaultFactory = new FrostyClmVaultFactory(address(0));
		deployer = new ClmPoolDeployer(strategyFactory, vaultFactory, owner);
		strategyFactory.addStrategy(deployer.STRATEGY_NAME(), address(new FrostyClmStrategy()));
		strategyFactory.addRebalancer(rebalancer);
	}

	/// @notice Writes deployments/base-mainnet-clm.json from what `deployer` recorded on chain.
	function writeDeployments(ClmPoolDeployer deployer) external {
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

	/// @dev Adds deployment `i` to the 'vaults' object and returns that object so far.
	function _vaultJson(ClmPoolDeployer deployer, uint256 i) private returns (string memory) {
		(string memory symbol, address pool, address gauge, address strategy, address vault) = deployer.deployments(i);
		vm.serializeAddress(symbol, 'vault', vault);
		vm.serializeAddress(symbol, 'strategy', strategy);
		vm.serializeAddress(symbol, 'pool', pool);
		return vm.serializeString('vaults', symbol, vm.serializeAddress(symbol, 'gauge', gauge));
	}
}

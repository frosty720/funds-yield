// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Test} from 'forge-std/Test.sol';
import {DeployClm} from '../../script/DeployClm.s.sol';
import {FrostyClmStrategy} from '../../contracts/strategies/velodrome/FrostyClmStrategy.sol';
import {FrostyClmStrategyFactory} from '../../contracts/strategies/FrostyClmStrategyFactory.sol';
import {FrostyClmVault} from '../../contracts/vault/FrostyClmVault.sol';
import {FrostyClmVaultFactory} from '../../contracts/vault/FrostyClmVaultFactory.sol';
import {ICLPoolLike} from './ClmForkBase.sol';

/// @dev Exposes DeployClm's JSON writer to the test.
contract DeployClmHarness is DeployClm {
	function write(
		FrostyClmStrategyFactory strategyFactory,
		FrostyClmVaultFactory vaultFactory,
		PoolConfig[] memory pools,
		FrostyClmStrategy[] memory strategies,
		FrostyClmVault[] memory vaults
	) external {
		_write(strategyFactory, vaultFactory, pools, strategies, vaults);
	}
}

/// @notice Rehearses DeployClm on a Base fork. Stock tokens (B20) can't run on a fork, so the full deploy runs on the
///         USDC/cbBTC test pool and the 10 stock entries get every check that only reads their pool.
contract DeployClmForkTest is Test {
	address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
	address internal constant SLIPSTREAM2_FACTORY = 0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef;
	address internal keeper = makeAddr('keeper');
	bool internal forked;
	DeployClmHarness internal script;

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		vm.createSelectFork(rpc, vm.envOr('BASE_FORK_BLOCK', uint256(52489276)));
		forked = true;
		script = new DeployClmHarness();
	}

	function test_deployCore_wiresTheFactory() public {
		vm.skip(!forked);
		(FrostyClmStrategyFactory strategyFactory,) = script.deployCore(keeper, keeper);
		assertEq(strategyFactory.treasury(), script.TREASURY());
		assertEq(strategyFactory.valueInterpreter(), script.VALUE_INTERPRETER());
		assertEq(strategyFactory.perfFeeBps(), 950);
		assertEq(strategyFactory.keeper(), keeper);
		assertTrue(strategyFactory.rebalancers(keeper));
		assertTrue(strategyFactory.getImplementation(script.STRATEGY_NAME()) != address(0));
	}

	function test_deployPool_onANonStockPool() public {
		vm.skip(!forked);
		(FrostyClmStrategyFactory strategyFactory, FrostyClmVaultFactory vaultFactory) = script.deployCore(keeper, keeper);
		DeployClm.PoolConfig memory cfg = DeployClm.PoolConfig({
			gauge: 0x7B0f1103746648FBfce9222f1266f79B934E16b2,
			maxTickDeviation: 5,
			pool: 0x160D7E9d948B16c163332a277b393c288408eb12,
			positionWidth: 30,
			stockToken: 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf,
			symbol: 'cbBTC',
			twapInterval: 120
		});
		(FrostyClmStrategy strategy, FrostyClmVault vault) = script.deployPool(strategyFactory, vaultFactory, cfg);
		assertEq(address(vault.strategy()), address(strategy));
		assertEq(strategy.vault(), address(vault));
		assertEq(strategy.pool(), cfg.pool);
		assertEq(strategy.gauge(), cfg.gauge);
		assertEq(strategy.compoundToken(), USDC);
		assertEq(strategy.maxTickDeviation(), 5);
		assertEq(strategy.owner(), address(script));
		assertEq(vault.symbol(), 'fcUSDC-cbBTC');
	}

	function test_stockConfig_matchesTheChain() public {
		vm.skip(!forked);
		DeployClm.PoolConfig[] memory pools = script.readPools();
		assertEq(pools.length, 10);
		for (uint256 i; i < pools.length; ++i) {
			ICLPoolLike p = ICLPoolLike(pools[i].pool);
			assertEq(p.factory(), SLIPSTREAM2_FACTORY, pools[i].symbol);
			assertEq(p.token0(), USDC, pools[i].symbol);
			assertEq(p.token1(), pools[i].stockToken, pools[i].symbol);
			assertEq(p.gauge(), pools[i].gauge, pools[i].symbol);
		}
	}

	function test_write_recordsEveryAddressPlans2to5Read() public {
		vm.skip(!forked);
		(FrostyClmStrategyFactory strategyFactory, FrostyClmVaultFactory vaultFactory) = script.deployCore(keeper, keeper);
		DeployClm.PoolConfig[] memory pools = new DeployClm.PoolConfig[](1);
		pools[0] = DeployClm.PoolConfig({
			gauge: 0x7B0f1103746648FBfce9222f1266f79B934E16b2,
			maxTickDeviation: 5,
			pool: 0x160D7E9d948B16c163332a277b393c288408eb12,
			positionWidth: 30,
			stockToken: 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf,
			symbol: 'cbBTC',
			twapInterval: 120
		});
		FrostyClmStrategy[] memory strategies = new FrostyClmStrategy[](1);
		FrostyClmVault[] memory vaults = new FrostyClmVault[](1);
		(strategies[0], vaults[0]) = script.deployPool(strategyFactory, vaultFactory, pools[0]);

		script.write(strategyFactory, vaultFactory, pools, strategies, vaults);
		string memory json = vm.readFile(script.OUTPUT_PATH());
		vm.removeFile(script.OUTPUT_PATH()); // the file must exist only after a real deploy

		assertEq(vm.parseJsonAddress(json, '.strategyFactory'), address(strategyFactory));
		assertEq(vm.parseJsonAddress(json, '.vaultFactory'), address(vaultFactory));
		assertEq(vm.parseJsonAddress(json, '.strategyImplementation'), strategyFactory.getImplementation(script.STRATEGY_NAME()));
		assertEq(vm.parseJsonString(json, '.strategyName'), script.STRATEGY_NAME());
		assertEq(vm.parseJsonAddress(json, '.vaults.cbBTC.vault'), address(vaults[0]));
		assertEq(vm.parseJsonAddress(json, '.vaults.cbBTC.strategy'), address(strategies[0]));
		assertEq(vm.parseJsonAddress(json, '.vaults.cbBTC.pool'), pools[0].pool);
		assertEq(vm.parseJsonAddress(json, '.vaults.cbBTC.gauge'), pools[0].gauge);
	}
}

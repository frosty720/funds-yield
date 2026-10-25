// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Test} from 'forge-std/Test.sol';
import {Ownable} from '@openzeppelin-4/contracts/access/Ownable.sol';
import {DeployClmV2} from '../../script/DeployClmV2.s.sol';
import {ClmPoolDeployerV2} from '../../contracts/deploy/ClmPoolDeployerV2.sol';
import {FrostyClmStrategyV2} from '../../contracts/strategies/aero/FrostyClmStrategyV2.sol';
import {FrostyClmStrategyFactory} from '../../contracts/strategies/FrostyClmStrategyFactory.sol';
import {FrostyClmVault} from '../../contracts/vault/FrostyClmVault.sol';
import {FrostyClmVaultFactory} from '../../contracts/vault/FrostyClmVaultFactory.sol';

interface IViAssetInfo {
	function getAssetInfo(address asset) external view returns (address aggregator, uint32, uint8, uint8);
}

interface IPoolPricedLookup {
	function poolPricedAdapter(address asset) external view returns (address);
}

interface IAeroPoolConfig {
	function factory() external view returns (address);
	function token0() external view returns (address);
	function token1() external view returns (address);
	function tickSpacing() external view returns (int24);
}

/// @notice Rehearses DeployClmV2 on a Base fork after the Aero upgrade (FrostyFi 2026-10-25), against v1's live strategy
///         factory and vault factory. The full pool deploy runs on the config's two entries without a stock token
///         (USDC-WETH, USDC-cbBTC); the stock entries (B20, which only Base's own node runs) get every check that only
///         reads their pool.
///         Run: BASE_MAINNET_RPC=<archive url> forge test --match-contract DeployClmV2Fork -vv
contract DeployClmV2ForkTest is Test {
	address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
	address internal constant AERO_CL_FACTORY = 0x9CB220581b91b0C83223012FE69688b92aD07a76;
	address internal constant TREASURY = 0x47b7702a4789912d0dfFDadC07c50395c293fF0A;
	address internal constant VALUE_INTERPRETER = 0x3CDbaBE5Bf4E6cfE10A2A326E0ad31b2d16398D4;
	address internal constant REGISTRAR_V2 = 0x60338a74c63EDeC7EC020cB9208DD234D9a2146F; // the live ClmVaultPriceFeed's registrar

	bool internal forked;
	DeployClmV2 internal script;
	FrostyClmStrategyFactory internal strategyFactory;
	FrostyClmVaultFactory internal vaultFactory;
	ClmPoolDeployerV2 internal deployer;
	address internal implementation;

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		vm.createSelectFork(rpc, vm.envOr('BASE_FORK_BLOCK_AERO', uint256(53_075_000)));
		vm.setEvmVersion('cancun'); // Aero's swap hook (pools' fee()) uses Cancun opcodes
		forked = true;
		script = new DeployClmV2();
		(strategyFactory, vaultFactory) = script.v1Factories();
		(implementation, deployer) = script.deployCore(address(this));
		// run()'s second call, made by the factory's owner (frosty-main) in the real broadcast
		address factoryOwner = Ownable(address(strategyFactory)).owner();
		string memory name = deployer.STRATEGY_NAME();
		vm.prank(factoryOwner);
		strategyFactory.addStrategy(name, implementation);
	}

	function test_core_addsV2ToV1sFactory() public {
		vm.skip(!forked);
		assertEq(strategyFactory.getImplementation(deployer.STRATEGY_NAME()), implementation);
		assertEq(address(deployer.strategyFactory()), address(strategyFactory));
		assertEq(address(deployer.vaultFactory()), address(vaultFactory));
		assertEq(deployer.owner(), address(this));
		// v1's settings carry over to every v2 strategy
		assertEq(strategyFactory.treasury(), TREASURY);
		assertEq(strategyFactory.perfFeeBps(), 950);
		assertTrue(strategyFactory.getImplementation('FrostyClmStrategy-v1') != implementation, 'v1 left as it is');
	}

	function test_config_everyPoolIsAnAeroPoolWithUsdc_andSaneSettings() public {
		vm.skip(!forked);
		ClmPoolDeployerV2.PoolConfig[] memory pools = script.readPools();
		assertEq(pools.length, 9);
		for (uint256 i; i < pools.length; ++i) {
			IAeroPoolConfig pool = IAeroPoolConfig(pools[i].pool);
			assertEq(pool.factory(), AERO_CL_FACTORY, pools[i].symbol);
			assertEq(pools[i].compoundToken, USDC, pools[i].symbol);
			assertTrue(pool.token0() == USDC || pool.token1() == USDC, pools[i].symbol);
			int24 spacing = pool.tickSpacing();
			int24 ticksASide = pools[i].positionWidth * spacing;
			assertTrue(ticksASide >= 400 && ticksASide <= 1_000, pools[i].symbol); // ±4%..±10%
			assertTrue(pools[i].maxTickDeviation > 0 && pools[i].maxTickDeviation < int56(spacing) * 40, pools[i].symbol);
			assertEq(pools[i].twapInterval, 120, pools[i].symbol);
			// funds-core ClmVaultPriceFeed._oracleFed: both tokens on an oracle feed, none pool-priced, or listing the
			// vault reverts (and with it ListClmVaults' whole batch: review 2026-10-25 found MUc and PLTRc)
			assertTrue(_oracleFed(pool.token0()) && _oracleFed(pool.token1()), pools[i].symbol);
		}
	}

	function test_deployPool_theNonStockEntries() public {
		vm.skip(!forked);
		ClmPoolDeployerV2.PoolConfig[] memory pools = script.readPools();
		uint256 deployed;
		for (uint256 i; i < pools.length; ++i) {
			if (keccak256(bytes(pools[i].symbol)) != keccak256('USDC-WETH') && keccak256(bytes(pools[i].symbol)) != keccak256('USDC-cbBTC')) continue;
			(FrostyClmStrategyV2 strategy, FrostyClmVault vault) = deployer.deployPool(pools[i]);
			assertEq(address(vault.strategy()), address(strategy));
			assertEq(strategy.vault(), address(vault));
			assertEq(strategy.pool(), pools[i].pool);
			assertEq(strategy.positionWidth(), pools[i].positionWidth);
			assertEq(strategy.maxTickDeviation(), pools[i].maxTickDeviation);
			assertEq(strategy.owner(), address(this), 'strategy ownership handed to the owner');
			assertEq(vault.owner(), address(this), 'vault ownership handed to the owner');
			(,, address gauge,,) = deployer.deployments(deployed);
			assertEq(gauge, address(0));
			++deployed;
		}
		assertEq(deployed, 2);
		assertEq(deployer.deploymentCount(), 2);
	}

	function _oracleFed(address token) internal view returns (bool) {
		(address aggregator,,,) = IViAssetInfo(VALUE_INTERPRETER).getAssetInfo(token);
		return aggregator != address(0) && IPoolPricedLookup(REGISTRAR_V2).poolPricedAdapter(token) == address(0);
	}
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Test} from 'forge-std/Test.sol';
import {DeployClm} from '../../script/DeployClm.s.sol';
import {ClmPoolDeployer} from '../../contracts/deploy/ClmPoolDeployer.sol';
import {FrostyClmStrategy} from '../../contracts/strategies/velodrome/FrostyClmStrategy.sol';
import {FrostyClmStrategyFactory} from '../../contracts/strategies/FrostyClmStrategyFactory.sol';
import {StratFeeManagerInitializable} from '../../contracts/strategies/StratFeeManagerInitializable.sol';
import {FrostyClmVault} from '../../contracts/vault/FrostyClmVault.sol';
import {FrostyClmVaultFactory} from '../../contracts/vault/FrostyClmVaultFactory.sol';
import {ICLPoolLike} from './ClmForkBase.sol';

/// @notice Rehearses the deploy on a Base fork (final review C1, 2026-10-11). forge simulates every script locally, and
///         stock tokens (B20) only run on Base's own node, so the forge script deploys the factories and ClmPoolDeployer
///         only, and each stock pool is deployed by `cast send ClmPoolDeployer.deployPool(...)`. Here the full pool
///         deploy runs on the USDC/cbBTC test pool and on every config entry without a stock token (2026-10-14); the
///         stock entries get every check that only reads their pool.
contract DeployClmForkTest is Test {
	address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
	address internal constant WETH = 0x4200000000000000000000000000000000000006;
	address internal constant SLIPSTREAM1_FACTORY = 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A;
	address internal constant SLIPSTREAM2_FACTORY = 0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef;
	address internal constant SLIPSTREAM3_FACTORY = 0xaDe65c38CD4849aDBA595a4323a8C7DdfE89716a;
	address internal constant MORPHO = 0xBAa5CC21fd487B8Fcc2F632f3F4E8D37262a0842;
	address internal keeper = makeAddr('keeper');
	address internal stranger = makeAddr('stranger');
	bool internal forked;
	DeployClm internal script;

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		vm.createSelectFork(rpc, vm.envOr('BASE_FORK_BLOCK', uint256(52489276)));
		forked = true;
		script = new DeployClm();
	}

	function _cbBtcConfig() internal pure returns (ClmPoolDeployer.PoolConfig memory) {
		return ClmPoolDeployer.PoolConfig({
			compoundToken: USDC,
			gauge: 0x7B0f1103746648FBfce9222f1266f79B934E16b2,
			maxTickDeviation: 5,
			pool: 0x160D7E9d948B16c163332a277b393c288408eb12,
			positionWidth: 30,
			symbol: 'USDC-cbBTC',
			twapInterval: 120
		});
	}

	function test_deployCore_wiresTheFactoryAndTheDeployer() public {
		vm.skip(!forked);
		(FrostyClmStrategyFactory strategyFactory, FrostyClmVaultFactory vaultFactory, ClmPoolDeployer deployer) =
			script.deployCore(keeper, keeper, address(this));
		assertEq(strategyFactory.treasury(), script.TREASURY());
		assertEq(strategyFactory.valueInterpreter(), script.VALUE_INTERPRETER());
		assertEq(strategyFactory.perfFeeBps(), 950);
		assertEq(strategyFactory.keeper(), keeper);
		assertTrue(strategyFactory.rebalancers(keeper));
		assertTrue(strategyFactory.getImplementation(deployer.STRATEGY_NAME()) != address(0));
		assertEq(address(deployer.strategyFactory()), address(strategyFactory));
		assertEq(address(deployer.vaultFactory()), address(vaultFactory));
		assertEq(deployer.owner(), address(this));
	}

	function test_deployPool_oneTransactionAndOwnershipToTheOwner() public {
		vm.skip(!forked);
		(,, ClmPoolDeployer deployer) = script.deployCore(keeper, keeper, address(this));
		ClmPoolDeployer.PoolConfig memory cfg = _cbBtcConfig();
		(FrostyClmStrategy strategy, FrostyClmVault vault) = deployer.deployPool(cfg);

		assertEq(address(vault.strategy()), address(strategy));
		assertEq(strategy.vault(), address(vault));
		assertEq(strategy.pool(), cfg.pool);
		assertEq(strategy.gauge(), cfg.gauge);
		assertEq(strategy.compoundToken(), USDC);
		assertEq(strategy.maxTickDeviation(), 5);
		assertEq(strategy.twapInterval(), 120);
		assertEq(strategy.strategist(), address(this));
		assertEq(strategy.owner(), address(this), 'strategy ownership handed to the owner');
		assertEq(vault.owner(), address(this), 'vault ownership handed to the owner');
		assertEq(vault.symbol(), 'fcUSDC-cbBTC');

		// Both proxies were initialized inside the same transaction: nobody can initialize them first.
		vm.expectRevert('Initializable: contract is already initialized');
		vault.initialize(address(strategy), 'x', 'x');
		StratFeeManagerInitializable.CommonAddresses memory common;
		vm.expectRevert('Initializable: contract is already initialized');
		strategy.initialize(cfg.pool, address(0), cfg.gauge, address(0), 1, address(1), USDC, common);

		assertEq(deployer.deploymentCount(), 1);
		(string memory symbol, address pool, address gauge, address s, address v) = deployer.deployments(0);
		assertEq(symbol, 'USDC-cbBTC');
		assertEq(pool, cfg.pool);
		assertEq(gauge, cfg.gauge);
		assertEq(s, address(strategy));
		assertEq(v, address(vault));
	}

	function test_deployPool_ownerOnly() public {
		vm.skip(!forked);
		(,, ClmPoolDeployer deployer) = script.deployCore(keeper, keeper, address(this));
		vm.prank(stranger);
		vm.expectRevert(ClmPoolDeployer.NotOwner.selector);
		deployer.deployPool(_cbBtcConfig());
	}

	function test_deployPool_refusesAWrongConfig() public {
		vm.skip(!forked);
		(,, ClmPoolDeployer deployer) = script.deployCore(keeper, keeper, address(this));
		ClmPoolDeployer.PoolConfig memory cfg = _cbBtcConfig();
		cfg.gauge = 0xA0B61fdB9f1FB9b917Fe38b49427Fd4D87472D28; // the WETH/USDC pool's gauge
		vm.expectRevert(abi.encodeWithSelector(ClmPoolDeployer.WrongPool.selector, 'USDC-cbBTC'));
		deployer.deployPool(cfg);
	}

	function test_writeDeployments_recordsEveryAddressPlans2to5Read() public {
		vm.skip(!forked);
		(FrostyClmStrategyFactory strategyFactory, FrostyClmVaultFactory vaultFactory, ClmPoolDeployer deployer) =
			script.deployCore(keeper, keeper, address(this));
		(FrostyClmStrategy strategy, FrostyClmVault vault) = deployer.deployPool(_cbBtcConfig());

		// the real deploy's book (committed 2026-10-14) is put back as it was: this test once deleted it
		bool hadBook = vm.exists(script.OUTPUT_PATH());
		string memory realBook = hadBook ? vm.readFile(script.OUTPUT_PATH()) : '';
		script.writeDeployments(deployer);
		string memory json = vm.readFile(script.OUTPUT_PATH());
		if (hadBook) vm.writeFile(script.OUTPUT_PATH(), realBook);
		else vm.removeFile(script.OUTPUT_PATH()); // the file must exist only after a real deploy

		assertEq(vm.parseJsonAddress(json, '.strategyFactory'), address(strategyFactory));
		assertEq(vm.parseJsonAddress(json, '.vaultFactory'), address(vaultFactory));
		assertEq(vm.parseJsonAddress(json, '.poolDeployer'), address(deployer));
		assertEq(vm.parseJsonAddress(json, '.strategyImplementation'), strategyFactory.getImplementation(deployer.STRATEGY_NAME()));
		assertEq(vm.parseJsonString(json, '.strategyName'), deployer.STRATEGY_NAME());
		assertEq(vm.parseJsonAddress(json, '.vaults.USDC-cbBTC.vault'), address(vault));
		assertEq(vm.parseJsonAddress(json, '.vaults.USDC-cbBTC.strategy'), address(strategy));
		assertEq(vm.parseJsonAddress(json, '.vaults.USDC-cbBTC.pool'), _cbBtcConfig().pool);
		assertEq(vm.parseJsonAddress(json, '.vaults.USDC-cbBTC.gauge'), _cbBtcConfig().gauge);
	}

	/// @notice Every entry: a pool of one of the three Slipstream deployments, its own gauge, and a compound token that is
	///         one of its two tokens and USDC or WETH. Harvests sell AERO in one hop on an Aerodrome basic pool, and only
	///         AERO/USDC and AERO/WETH are deep (2026-10-14: AERO/cbBTC held 807 AERO, AERO/EURC 0, AERO/cbXRP 2). No AERO
	///         pair: the strategy refuses a pool holding its own reward token (FrostyClmStrategy.initialize, InvalidInput).
	function test_poolConfig_matchesTheChain() public {
		vm.skip(!forked);
		ClmPoolDeployer.PoolConfig[] memory pools = script.readPools();
		assertEq(pools.length, 25);
		for (uint256 i; i < pools.length; ++i) {
			ICLPoolLike p = ICLPoolLike(pools[i].pool);
			address f = p.factory();
			assertTrue(f == SLIPSTREAM1_FACTORY || f == SLIPSTREAM2_FACTORY || f == SLIPSTREAM3_FACTORY, pools[i].symbol);
			assertTrue(pools[i].compoundToken == USDC || pools[i].compoundToken == WETH, pools[i].symbol);
			assertTrue(p.token0() == pools[i].compoundToken || p.token1() == pools[i].compoundToken, pools[i].symbol);
			assertEq(p.gauge(), pools[i].gauge, pools[i].symbol);
			// A stock token (B20) runs no code on a fork, not even symbol(): labels aren't checked here.
		}
	}

	/// @notice Every entry without a stock token deploys for real on the fork, as `cast send deployPool` will on Base,
	///         except WETH-MORPHO: MORPHO's code uses an opcode newer than this repo's pinned paris EVM (NotActivated on
	///         approve), so it only runs on Base itself (the deploy script's CHECK_ONLY mode eth_calls it there).
	function test_poolConfig_everyNonStockEntryDeploys() public {
		vm.skip(!forked);
		(,, ClmPoolDeployer deployer) = script.deployCore(keeper, keeper, address(this));
		ClmPoolDeployer.PoolConfig[] memory pools = script.readPools();
		uint256 deployed;
		for (uint256 i; i < pools.length; ++i) {
			ICLPoolLike p = ICLPoolLike(pools[i].pool);
			if (_isStock(p.token0()) || _isStock(p.token1()) || p.token0() == MORPHO || p.token1() == MORPHO) continue;
			(FrostyClmStrategy strategy, FrostyClmVault vault) = deployer.deployPool(pools[i]);
			assertEq(strategy.compoundToken(), pools[i].compoundToken, pools[i].symbol);
			assertEq(vault.name(), string.concat('FrostyFi CLM ', pools[i].symbol));
			++deployed;
		}
		assertEq(deployed, 14);
	}

	/// @dev Coinbase's B20 stock tokens live at 0xb2000000000000000000…: a Base precompile Foundry can't run.
	function _isStock(address token) private pure returns (bool) {
		return uint160(token) >> 80 == 0xb2000000000000000000;
	}

	function test_deployPool_slipstream1WethPair() public {
		vm.skip(!forked);
		(,, ClmPoolDeployer deployer) = script.deployCore(keeper, keeper, address(this));
		(FrostyClmStrategy strategy, FrostyClmVault vault) = deployer.deployPool(
			ClmPoolDeployer.PoolConfig({
				compoundToken: 0x4200000000000000000000000000000000000006,
				gauge: 0x88040de1F5811090b638Fa70633B24a3e319D06f,
				maxTickDeviation: 20,
				pool: 0x200681425b0C8D78C6a467512C5D49FA56BaC88A,
				positionWidth: 8,
				symbol: 'WETH-cbLTC',
				twapInterval: 120
			})
		);
		assertEq(strategy.nftManager(), 0x827922686190790b37229fd06084350E74485b72, 'Slipstream-1 NFT manager');
		assertEq(strategy.compoundToken(), 0x4200000000000000000000000000000000000006);
		assertEq(vault.symbol(), 'fcWETH-cbLTC');
		assertEq(vault.name(), 'FrostyFi CLM WETH-cbLTC');
	}

	function test_deployPool_slipstream3() public {
		vm.skip(!forked);
		(,, ClmPoolDeployer deployer) = script.deployCore(keeper, keeper, address(this));
		// USDC/RNBW: CLAWD (USDC/CLAWD) uses an opcode newer than paris, which this repo's pinned EVM can't run on a fork.
		(FrostyClmStrategy strategy,) = deployer.deployPool(
			ClmPoolDeployer.PoolConfig({
				compoundToken: USDC,
				gauge: 0x0099140A97ACc1cc831ECB39Ab5FD60FC9F6BB64,
				maxTickDeviation: 20,
				pool: 0x4bf85cA48a620BAf9DDE3b6A7A6d88b219827caA,
				positionWidth: 18,
				symbol: 'USDC-RNBW',
				twapInterval: 120
			})
		);
		assertEq(strategy.nftManager(), 0xa990C6a764b73BF43cee5Bb40339c3322FB9D55F, 'Slipstream-3 NFT manager');
	}

	function test_deployPool_refusesACompoundTokenWithoutAnAeroPool() public {
		vm.skip(!forked);
		(,, ClmPoolDeployer deployer) = script.deployCore(keeper, keeper, address(this));
		vm.expectRevert(abi.encodeWithSelector(ClmPoolDeployer.WrongPool.selector, 'WETH-cbLTC'));
		deployer.deployPool(
			ClmPoolDeployer.PoolConfig({
				compoundToken: 0xcb17C9Db87B595717C857a08468793f5bAb6445F, // cbLTC: Aerodrome has no AERO/cbLTC basic pool
				gauge: 0x88040de1F5811090b638Fa70633B24a3e319D06f,
				maxTickDeviation: 20,
				pool: 0x200681425b0C8D78C6a467512C5D49FA56BaC88A,
				positionWidth: 8,
				symbol: 'WETH-cbLTC',
				twapInterval: 120
			})
		);
	}

	function test_deployPool_refusesAPoolOutsideSlipstream() public {
		vm.skip(!forked);
		(,, ClmPoolDeployer deployer) = script.deployCore(keeper, keeper, address(this));
		vm.expectRevert(abi.encodeWithSelector(ClmPoolDeployer.WrongPool.selector, 'UNI'));
		deployer.deployPool(
			ClmPoolDeployer.PoolConfig({
				compoundToken: USDC,
				gauge: 0x7B0f1103746648FBfce9222f1266f79B934E16b2,
				maxTickDeviation: 5,
				pool: 0xfBB6Eed8e7aa03B138556eeDaF5D271A5E1e43ef, // Uniswap v3 USDC/cbBTC
				positionWidth: 30,
				symbol: 'UNI',
				twapInterval: 120
			})
		);
	}
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Script, console} from 'forge-std/Script.sol';
import {FrostyClmStrategy} from '../contracts/strategies/velodrome/FrostyClmStrategy.sol';
import {FrostyClmStrategyFactory} from '../contracts/strategies/FrostyClmStrategyFactory.sol';
import {StratFeeManagerInitializable} from '../contracts/strategies/StratFeeManagerInitializable.sol';
import {FrostyClmVault} from '../contracts/vault/FrostyClmVault.sol';
import {FrostyClmVaultFactory} from '../contracts/vault/FrostyClmVaultFactory.sol';

interface ICLPoolConfig {
	function token0() external view returns (address);
	function token1() external view returns (address);
	function gauge() external view returns (address);
	function factory() external view returns (address);
}

/// @notice Deploys FrostyFi's CLM on Base: the strategy implementation behind a beacon, both factories, and one strategy
///         and vault per pool in script/config/base-mainnet-pools.json (Beefy's live settings, 2026-10-11).
///         Run: KEEPER_ADDRESS=<keeper Engine wallet> forge script script/DeployClm.s.sol --rpc-url base
///              --account frosty-main --sender <deployer> --broadcast --slow --verify
///         Each `initialize` is its own transaction. If someone initializes a fresh proxy first, ours reverts and the
///         run stops: that proxy is abandoned (it never held funds) and the run is repeated.
contract DeployClm is Script {
	/// @dev Field order is alphabetical: vm.parseJson decodes object keys in that order.
	struct PoolConfig {
		address gauge;
		int56 maxTickDeviation;
		address pool;
		int24 positionWidth;
		address stockToken;
		string symbol;
		uint32 twapInterval;
	}

	address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
	address public constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
	address public constant SLIPSTREAM2_FACTORY = 0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef;
	address public constant NFT_MANAGER = 0xe1f8cd9AC4e4A65F54f38a5CdAfCA44f6dD68b53;
	address public constant AERO_ROUTER = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;
	address public constant AERO_POOL_FACTORY = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;
	address public constant VALUE_INTERPRETER = 0x3CDbaBE5Bf4E6cfE10A2A326E0ad31b2d16398D4;
	address public constant TREASURY = 0x47b7702a4789912d0dfFDadC07c50395c293fF0A;
	uint256 public constant PERF_FEE_BPS = 950; // 9.5%, Beefy's total fee (founder 2026-10-11)
	string public constant STRATEGY_NAME = 'FrostyClmStrategy-v1';
	string public constant POOLS_PATH = 'script/config/base-mainnet-pools.json';
	string public constant OUTPUT_PATH = 'deployments/base-mainnet-clm.json';

	error WrongPool(string symbol);

	function run() external {
		address keeper = vm.envAddress('KEEPER_ADDRESS');
		address rebalancer = vm.envOr('REBALANCER_ADDRESS', keeper);
		PoolConfig[] memory pools = readPools();

		vm.startBroadcast();
		(FrostyClmStrategyFactory strategyFactory, FrostyClmVaultFactory vaultFactory) = deployCore(keeper, rebalancer);
		FrostyClmStrategy[] memory strategies = new FrostyClmStrategy[](pools.length);
		FrostyClmVault[] memory vaults = new FrostyClmVault[](pools.length);
		for (uint256 i; i < pools.length; ++i) {
			(strategies[i], vaults[i]) = deployPool(strategyFactory, vaultFactory, pools[i]);
		}
		vm.stopBroadcast();

		_write(strategyFactory, vaultFactory, pools, strategies, vaults);
	}

	function readPools() public view returns (PoolConfig[] memory) {
		return abi.decode(vm.parseJson(vm.readFile(POOLS_PATH)), (PoolConfig[]));
	}

	function deployCore(address keeper, address rebalancer)
		public
		returns (FrostyClmStrategyFactory strategyFactory, FrostyClmVaultFactory vaultFactory)
	{
		strategyFactory = new FrostyClmStrategyFactory(keeper, TREASURY, VALUE_INTERPRETER, PERF_FEE_BPS);
		strategyFactory.addStrategy(STRATEGY_NAME, address(new FrostyClmStrategy()));
		strategyFactory.addRebalancer(rebalancer);
		vaultFactory = new FrostyClmVaultFactory(address(0));
	}

	function deployPool(FrostyClmStrategyFactory strategyFactory, FrostyClmVaultFactory vaultFactory, PoolConfig memory cfg)
		public
		returns (FrostyClmStrategy strategy, FrostyClmVault vault)
	{
		_checkPool(cfg);
		strategy = FrostyClmStrategy(payable(strategyFactory.createStrategy(STRATEGY_NAME)));
		vault = vaultFactory.cloneVault();
		vault.initialize(
			address(strategy), string.concat('FrostyFi CLM USDC/', cfg.symbol), string.concat('fcUSDC-', cfg.symbol)
		);
		_initializeStrategy(strategy, address(vault), address(strategyFactory), cfg);
		strategy.setDeviation(cfg.maxTickDeviation);
		if (cfg.twapInterval != strategy.twapInterval()) strategy.setTwapInterval(cfg.twapInterval);
	}

	/// @dev The config must name a Slipstream-2 USDC/stock pool and that pool's own gauge.
	function _checkPool(PoolConfig memory cfg) private view {
		ICLPoolConfig pool = ICLPoolConfig(cfg.pool);
		if (
			pool.factory() != SLIPSTREAM2_FACTORY || pool.token0() != USDC || pool.token1() != cfg.stockToken
				|| pool.gauge() != cfg.gauge
		) revert WrongPool(cfg.symbol);
	}

	function _initializeStrategy(FrostyClmStrategy strategy, address vault, address strategyFactory, PoolConfig memory cfg)
		private
	{
		StratFeeManagerInitializable.CommonAddresses memory common = StratFeeManagerInitializable.CommonAddresses({
			vault: vault, unirouter: AERO_ROUTER, strategist: msg.sender, factory: strategyFactory
		});
		strategy.initialize(cfg.pool, NFT_MANAGER, cfg.gauge, AERO, cfg.positionWidth, AERO_POOL_FACTORY, USDC, common);
	}

	function _write(
		FrostyClmStrategyFactory strategyFactory,
		FrostyClmVaultFactory vaultFactory,
		PoolConfig[] memory pools,
		FrostyClmStrategy[] memory strategies,
		FrostyClmVault[] memory vaults
	) internal {
		string memory vaultsJson;
		for (uint256 i; i < pools.length; ++i) {
			vaultsJson = vm.serializeString('vaults', pools[i].symbol, _vaultJson(pools[i], strategies[i], vaults[i]));
		}
		vm.serializeAddress('clm', 'strategyFactory', address(strategyFactory));
		vm.serializeAddress('clm', 'vaultFactory', address(vaultFactory));
		vm.serializeAddress('clm', 'strategyImplementation', strategyFactory.getImplementation(STRATEGY_NAME));
		vm.serializeString('clm', 'strategyName', STRATEGY_NAME);
		vm.writeJson(vm.serializeString('clm', 'vaults', vaultsJson), OUTPUT_PATH);
		console.log('wrote', OUTPUT_PATH);
	}

	function _vaultJson(PoolConfig memory cfg, FrostyClmStrategy strategy, FrostyClmVault vault)
		private
		returns (string memory)
	{
		vm.serializeAddress(cfg.symbol, 'vault', address(vault));
		vm.serializeAddress(cfg.symbol, 'strategy', address(strategy));
		vm.serializeAddress(cfg.symbol, 'pool', cfg.pool);
		return vm.serializeAddress(cfg.symbol, 'gauge', cfg.gauge);
	}
}

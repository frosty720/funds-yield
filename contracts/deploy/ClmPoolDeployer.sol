// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {FrostyClmStrategy} from '../strategies/velodrome/FrostyClmStrategy.sol';
import {FrostyClmStrategyFactory} from '../strategies/FrostyClmStrategyFactory.sol';
import {StratFeeManagerInitializable} from '../strategies/StratFeeManagerInitializable.sol';
import {FrostyClmVault} from '../vault/FrostyClmVault.sol';
import {FrostyClmVaultFactory} from '../vault/FrostyClmVaultFactory.sol';

interface IAerodromePoolFactory {
	function getPool(address tokenA, address tokenB, bool stable) external view returns (address);
}

interface ICLPoolConfig {
	function token0() external view returns (address);
	function token1() external view returns (address);
	function gauge() external view returns (address);
	function factory() external view returns (address);
}

/// @title ClmPoolDeployer
/// @notice FrostyFi 2026-10-11 (final review C1): deploys one Slipstream pool's strategy and vault in a single
///         transaction, then hands both to `owner`. Any of the three Slipstream deployments and any pair whose compound
///         token has a basic AERO pool (plan 1b, 2026-10-13).
///         - Called with `cast send`, never from a forge script: the strategy's initialize approves the pool's B20
///           stock token, whose code only Base's own node runs, and forge simulates every script locally first
///           (MAINNET_RUNBOOK_FUNDS.md: "must use cast, not forge" for stock tokens).
///         - One transaction also means nobody can initialize the new proxies before us.
contract ClmPoolDeployer {
	/// @dev Field order is alphabetical: vm.parseJson decodes object keys in that order.
	struct PoolConfig {
		address compoundToken;
		address gauge;
		int56 maxTickDeviation;
		address pool;
		int24 positionWidth;
		string symbol;
		uint32 twapInterval;
	}

	struct Deployment {
		string symbol;
		address pool;
		address gauge;
		address strategy;
		address vault;
	}

	address public constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
	address public constant SLIPSTREAM1_FACTORY = 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A;
	address public constant SLIPSTREAM1_NFT_MANAGER = 0x827922686190790b37229fd06084350E74485b72;
	address public constant SLIPSTREAM2_FACTORY = 0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef;
	address public constant SLIPSTREAM2_NFT_MANAGER = 0xe1f8cd9AC4e4A65F54f38a5CdAfCA44f6dD68b53;
	address public constant SLIPSTREAM3_FACTORY = 0xaDe65c38CD4849aDBA595a4323a8C7DdfE89716a;
	address public constant SLIPSTREAM3_NFT_MANAGER = 0xa990C6a764b73BF43cee5Bb40339c3322FB9D55F;
	address public constant AERO_ROUTER = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;
	address public constant AERO_POOL_FACTORY = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;
	string public constant STRATEGY_NAME = 'FrostyClmStrategy-v1';

	FrostyClmStrategyFactory public immutable strategyFactory;
	FrostyClmVaultFactory public immutable vaultFactory;
	/// @notice The only caller of deployPool; receives ownership of every strategy and vault deployed here.
	address public immutable owner;

	/// @notice Every pool deployed here, in order: what deployments/base-mainnet-clm.json is written from.
	Deployment[] public deployments;

	event PoolDeployed(string symbol, address indexed pool, address strategy, address vault);

	error NotOwner();
	error WrongPool(string symbol);

	constructor(FrostyClmStrategyFactory _strategyFactory, FrostyClmVaultFactory _vaultFactory, address _owner) {
		strategyFactory = _strategyFactory;
		vaultFactory = _vaultFactory;
		owner = _owner;
	}

	function deployPool(PoolConfig calldata cfg) external returns (FrostyClmStrategy strategy, FrostyClmVault vault) {
		if (msg.sender != owner) revert NotOwner();
		address nftManager = _checkPool(cfg);
		strategy = FrostyClmStrategy(payable(strategyFactory.createStrategy(STRATEGY_NAME)));
		vault = vaultFactory.cloneVault();
		vault.initialize(address(strategy), string.concat('FrostyFi CLM ', cfg.symbol), string.concat('fc', cfg.symbol));
		_initializeStrategy(strategy, address(vault), nftManager, cfg);
		strategy.setDeviation(cfg.maxTickDeviation);
		if (cfg.twapInterval != strategy.twapInterval()) strategy.setTwapInterval(cfg.twapInterval);
		strategy.transferOwnership(owner);
		vault.transferOwnership(owner);

		deployments.push(Deployment(cfg.symbol, cfg.pool, cfg.gauge, address(strategy), address(vault)));
		emit PoolDeployed(cfg.symbol, cfg.pool, address(strategy), address(vault));
	}

	function deploymentCount() external view returns (uint256) {
		return deployments.length;
	}

	/// @notice The Slipstream NFT manager of `factory`, or 0 for anything else (each Slipstream deployment has its own).
	function nftManagerOf(address factory) public pure returns (address) {
		if (factory == SLIPSTREAM1_FACTORY) return SLIPSTREAM1_NFT_MANAGER;
		if (factory == SLIPSTREAM2_FACTORY) return SLIPSTREAM2_NFT_MANAGER;
		if (factory == SLIPSTREAM3_FACTORY) return SLIPSTREAM3_NFT_MANAGER;
		return address(0);
	}

	/// @dev FrostyFi 2026-10-13 (plan 1b): a Slipstream pool (any of the three deployments), its own gauge, and a
	///      compound token that is a pool token with a basic AERO pool on Aerodrome (the harvest's one-hop sale).
	///      The factory check comes first, so a non-Slipstream pool (no `gauge()`) is refused before that call.
	function _checkPool(PoolConfig calldata cfg) private view returns (address nftManager) {
		ICLPoolConfig pool = ICLPoolConfig(cfg.pool);
		nftManager = nftManagerOf(pool.factory());
		if (
			nftManager == address(0) || pool.gauge() != cfg.gauge
				|| (cfg.compoundToken != pool.token0() && cfg.compoundToken != pool.token1())
				|| IAerodromePoolFactory(AERO_POOL_FACTORY).getPool(AERO, cfg.compoundToken, false) == address(0)
		) revert WrongPool(cfg.symbol);
	}

	function _initializeStrategy(FrostyClmStrategy strategy, address vault, address nftManager, PoolConfig calldata cfg)
		private
	{
		StratFeeManagerInitializable.CommonAddresses memory common = StratFeeManagerInitializable.CommonAddresses({
			vault: vault, unirouter: AERO_ROUTER, strategist: owner, factory: address(strategyFactory)
		});
		strategy.initialize(
			cfg.pool, nftManager, cfg.gauge, AERO, cfg.positionWidth, AERO_POOL_FACTORY, cfg.compoundToken, common
		);
	}
}

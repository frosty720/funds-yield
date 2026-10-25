// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {FrostyClmStrategyV2} from '../strategies/aero/FrostyClmStrategyV2.sol';
import {FrostyClmStrategyFactory} from '../strategies/FrostyClmStrategyFactory.sol';
import {StratFeeManagerInitializable} from '../strategies/StratFeeManagerInitializable.sol';
import {FrostyClmVault} from '../vault/FrostyClmVault.sol';
import {FrostyClmVaultFactory} from '../vault/FrostyClmVaultFactory.sol';

interface ICLPoolConfig {
	function token0() external view returns (address);
	function token1() external view returns (address);
	function factory() external view returns (address);
}

/// @title ClmPoolDeployerV2
/// @notice ClmPoolDeployer for FrostyClmStrategyV2 on Aero's Slipstream pools (FrostyFi 2026-10-25): deploys one pool's
///         strategy and vault in a single transaction, then hands both to `owner` (final review C1, 2026-10-11). No gauge
///         and no sale route: v2 earns the pool's fees.
///         - Called with `cast send`, never from a forge script: the strategy's initialize approves the pool's B20
///           stock token, whose code only Base's own node runs, and forge simulates every script locally first
///           (MAINNET_RUNBOOK_FUNDS.md: "must use cast, not forge" for stock tokens).
///         - One transaction also means nobody can initialize the new proxies before us.
contract ClmPoolDeployerV2 {
	/// @dev Field order is alphabetical: vm.parseJson decodes object keys in that order.
	struct PoolConfig {
		address compoundToken;
		int56 maxTickDeviation;
		address pool;
		int24 positionWidth;
		string symbol;
		uint32 twapInterval;
	}

	/// @dev ClmPoolDeployer's shape, so the keeper and the sync read both alike; `gauge` is always 0 (v2 never stakes).
	struct Deployment {
		string symbol;
		address pool;
		address gauge;
		address strategy;
		address vault;
	}

	/// @notice Aero's Slipstream deployment on Base (Dromos-Labs metadex-slipstream-public deployment-addresses/cl-base.json,
	///         checked on chain 2026-10-25: the NFT manager's factory()).
	address public constant AERO_CL_FACTORY = 0x9CB220581b91b0C83223012FE69688b92aD07a76;
	address public constant AERO_NFT_MANAGER = 0x4857DB576eE0e45F10525eC59527BfD10beeC60b;
	string public constant STRATEGY_NAME = 'FrostyClmStrategy-v2';

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

	function deployPool(PoolConfig calldata cfg) external returns (FrostyClmStrategyV2 strategy, FrostyClmVault vault) {
		if (msg.sender != owner) revert NotOwner();
		_checkPool(cfg);
		strategy = FrostyClmStrategyV2(payable(strategyFactory.createStrategy(STRATEGY_NAME)));
		vault = vaultFactory.cloneVault();
		vault.initialize(address(strategy), string.concat('FrostyFi CLM ', cfg.symbol), string.concat('fc', cfg.symbol));
		_initializeStrategy(strategy, address(vault), cfg);
		strategy.setDeviation(cfg.maxTickDeviation);
		if (cfg.twapInterval != strategy.twapInterval()) strategy.setTwapInterval(cfg.twapInterval);
		strategy.transferOwnership(owner);
		vault.transferOwnership(owner);

		deployments.push(Deployment(cfg.symbol, cfg.pool, address(0), address(strategy), address(vault)));
		emit PoolDeployed(cfg.symbol, cfg.pool, address(strategy), address(vault));
	}

	function deploymentCount() external view returns (uint256) {
		return deployments.length;
	}

	/// @dev An Aero Slipstream pool, and a compound token that is one of its tokens.
	function _checkPool(PoolConfig calldata cfg) private view {
		ICLPoolConfig pool = ICLPoolConfig(cfg.pool);
		if (
			pool.factory() != AERO_CL_FACTORY
				|| (cfg.compoundToken != pool.token0() && cfg.compoundToken != pool.token1())
		) revert WrongPool(cfg.symbol);
	}

	/// @dev No router: v2 sells nothing.
	function _initializeStrategy(FrostyClmStrategyV2 strategy, address vault, PoolConfig calldata cfg) private {
		StratFeeManagerInitializable.CommonAddresses memory common = StratFeeManagerInitializable.CommonAddresses({
			vault: vault, unirouter: address(0), strategist: owner, factory: address(strategyFactory)
		});
		strategy.initialize(cfg.pool, AERO_NFT_MANAGER, cfg.positionWidth, cfg.compoundToken, common);
	}
}

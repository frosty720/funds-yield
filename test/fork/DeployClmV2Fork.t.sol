// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Vm} from 'forge-std/Vm.sol';
import {Ownable} from '@openzeppelin-4/contracts/access/Ownable.sol';
import {IERC20} from '@openzeppelin-4/contracts/token/ERC20/IERC20.sol';
import {IERC721} from '@openzeppelin-4/contracts/token/ERC721/IERC721.sol';
import {DeployClmV2} from '../../script/DeployClmV2.s.sol';
import {ClmPoolDeployerV2} from '../../contracts/deploy/ClmPoolDeployerV2.sol';
import {FrostyClmStrategyV2} from '../../contracts/strategies/aero/FrostyClmStrategyV2.sol';
import {FrostyClmStrategyFactory} from '../../contracts/strategies/FrostyClmStrategyFactory.sol';
import {FrostyClmVault} from '../../contracts/vault/FrostyClmVault.sol';
import {FrostyClmVaultFactory} from '../../contracts/vault/FrostyClmVaultFactory.sol';
import {FullMath} from '../../contracts/utils/FullMath.sol';
import {TickMath} from '../../contracts/utils/TickMath.sol';
import {B20Fork, B20StandIn} from '../utils/B20Fork.sol';

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
	function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, bool);
	function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data)
		external
		returns (int256 amount0, int256 amount1);
}

/// @notice Rehearses DeployClmV2 on a Base fork after the Aero upgrade (FrostyFi 2026-10-25), against v1's live strategy
///         factory and vault factory: every entry of the config deploys, takes a deposit, harvests and pays it back. The
///         stock entries (B20 tokens, which only Base's own node runs) trade against a stand-in holding the pool's real
///         reserves (test/utils/B20Fork.sol), and the real token's transfer rules are read from Base for every contract
///         that moves it. The fork block is a Sunday: the stock feeds hold Friday's close while the pools trade.
///         Run: BASE_MAINNET_RPC=<archive url> forge test --match-contract DeployClmV2Fork -vv
contract DeployClmV2ForkTest is B20Fork {
	address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
	address internal constant WETH = 0x4200000000000000000000000000000000000006;
	address internal constant AERO_CL_FACTORY = 0x9CB220581b91b0C83223012FE69688b92aD07a76;
	address internal constant TREASURY = 0x47b7702a4789912d0dfFDadC07c50395c293fF0A;
	address internal constant VALUE_INTERPRETER = 0x3CDbaBE5Bf4E6cfE10A2A326E0ad31b2d16398D4;
	address internal constant REGISTRAR_V2 = 0x60338a74c63EDeC7EC020cB9208DD234D9a2146F; // the live ClmVaultPriceFeed's registrar
	address internal constant AERO_NFT_MANAGER = 0x4857DB576eE0e45F10525eC59527BfD10beeC60b;
	uint256 internal constant DURATION = 1 days; // StratFeeManagerInitializable.DURATION: harvested fees unlock over it
	uint256 internal constant PERF_FEE_BPS = 950; // v1's factory setting, which v2 strategies share
	bytes32 internal constant FEES_COLLECTED = keccak256('FeesCollected(uint256,uint256,uint256,uint256)');

	address internal alice = makeAddr('alice');
	address internal swapping; // the pool the test is swapping on

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

	function test_config_everyPoolIsAnAeroPool_compoundingUsdcOrWeth_andSaneSettings() public {
		vm.skip(!forked);
		ClmPoolDeployerV2.PoolConfig[] memory pools = script.readPools();
		assertEq(pools.length, 14);
		for (uint256 i; i < pools.length; ++i) {
			IAeroPoolConfig pool = IAeroPoolConfig(pools[i].pool);
			assertEq(pool.factory(), AERO_CL_FACTORY, pools[i].symbol);
			// USDC pairs compound USDC; WETH pairs WETH, as v1's (2026-10-14): the terminal values both
			assertTrue(pools[i].compoundToken == USDC || pools[i].compoundToken == WETH, pools[i].symbol);
			assertTrue(pool.token0() == pools[i].compoundToken || pool.token1() == pools[i].compoundToken, pools[i].symbol);
			int24 spacing = pool.tickSpacing();
			int24 ticksASide = pools[i].positionWidth * spacing;
			// ±4% (stocks) .. ±35%: the volatile WETH pairs keep v1's wide ranges (founder 2026-10-25)
			assertTrue(ticksASide >= 400 && ticksASide <= 3_000, pools[i].symbol);
			assertTrue(pools[i].maxTickDeviation > 0 && pools[i].maxTickDeviation < int56(spacing) * 40, pools[i].symbol);
			assertEq(pools[i].twapInterval, 120, pools[i].symbol);
			// funds-core ClmVaultPriceFeed._oracleFed: both tokens on an oracle feed, none pool-priced, or listing the
			// vault reverts (and with it ListClmVaults' whole batch: review 2026-10-25 found MUc and PLTRc)
			assertTrue(_oracleFed(pool.token0()) && _oracleFed(pool.token1()), pools[i].symbol);
		}
	}

	function test_deployPool_theNonStockEntries_takeADeposit_harvestFees_andPayItAllBack() public {
		vm.skip(!forked);
		assertEq(_roundTrips(false), 6); // USDC-WETH, USDC-cbBTC, WETH-USDT, WETH-EURC, WETH-VVV, WETH-MORPHO
	}

	function test_deployPool_theStockEntries_takeADeposit_harvestFees_andPayItAllBack() public {
		vm.skip(!forked);
		assertEq(_roundTrips(true), 8);
	}

	/// @dev Every entry with (`stocks`) or without a B20 token, round-tripped; returns how many.
	function _roundTrips(bool stocks) internal returns (uint256 done) {
		ClmPoolDeployerV2.PoolConfig[] memory pools = script.readPools();
		for (uint256 i; i < pools.length; ++i) {
			IAeroPoolConfig pool = IAeroPoolConfig(pools[i].pool);
			if ((_isB20(pool.token0()) || _isB20(pool.token1())) != stocks) continue;
			_roundTrip(pools[i]);
			++done;
		}
	}

	/// @dev One entry: deploy; a B20 token gets the stand-in, and the live token must let the pool, the strategy, the
	///      vault and the NFT manager move it; a first deposit of 10,000 USDC or 3 WETH (token0) and twice its worth of
	///      token1 (the vault takes what its range needs); trades both ways; a harvest that pays the Treasury its cut in
	///      both tokens; and, once the fees have unlocked, a whole exit worth at least what went in.
	function _roundTrip(ClmPoolDeployerV2.PoolConfig memory cfg) internal {
		address t1 = IAeroPoolConfig(cfg.pool).token1();
		address[] memory holders = new address[](1);
		holders[0] = cfg.pool;
		if (_isB20(t1)) _standIn(t1, holders); // token0 is always USDC or WETH here
		(FrostyClmStrategyV2 strategy, FrostyClmVault vault) = _deployChecked(cfg);
		if (_isB20(t1)) {
			address[4] memory movers = [cfg.pool, address(strategy), address(vault), AERO_NFT_MANAGER];
			for (uint256 j; j < movers.length; ++j) {
				assertTrue(_b20Allows(t1, movers[j]), string.concat(cfg.symbol, ': the live token blocks a contract of the flow'));
			}
		}
		assertTrue(vault.isCalm(), string.concat(cfg.symbol, ': calm at the fork block'));
		(uint256 valueIn, uint256 amount0) = _firstDeposit(cfg, vault);
		(uint256 mainId,,) = strategy.positionMain();
		assertEq(IERC721(AERO_NFT_MANAGER).ownerOf(mainId), address(strategy), cfg.symbol);
		_tradeAndHarvest(cfg, strategy, amount0);
		_exitAll(cfg, vault, valueIn);
	}

	/// @dev Alice's first deposit: 10,000 USDC or 3 WETH (token0) and twice its worth of token1; the vault takes what its
	///      range needs. Returns what it took, in token0, and the token0 amount offered.
	function _firstDeposit(ClmPoolDeployerV2.PoolConfig memory cfg, FrostyClmVault vault)
		internal
		returns (uint256 valueIn, uint256 amount0)
	{
		IAeroPoolConfig pool = IAeroPoolConfig(cfg.pool);
		(address t0, address t1) = (pool.token0(), pool.token1());
		require(t0 == USDC || t0 == WETH, 'token0 is USDC or WETH');
		amount0 = t0 == USDC ? 10_000e6 : 3 ether;
		(uint160 sqrtP,,,,,) = pool.slot0();
		uint256 amount1 = 2 * FullMath.mulDiv(FullMath.mulDiv(amount0, sqrtP, 1 << 96), sqrtP, 1 << 96);
		_give(t0, alice, amount0);
		_give(t1, alice, amount1);
		// what she holds now, an earlier entry's exit included: the deposit takes from it
		uint256[2] memory held = [IERC20(t0).balanceOf(alice), IERC20(t1).balanceOf(alice)];
		vm.startPrank(alice);
		IERC20(t0).approve(address(vault), type(uint256).max);
		IERC20(t1).approve(address(vault), type(uint256).max);
		vault.deposit(amount0, amount1, 0);
		vm.stopPrank();
		valueIn = _value0(cfg.pool, held[0] - IERC20(t0).balanceOf(alice), held[1] - IERC20(t1).balanceOf(alice));
		assertGt(vault.balanceOf(alice), 0, cfg.symbol);
		skip(uint256(cfg.twapInterval) + 1);
	}

	/// @dev Trades both ways, then a harvest that collects fees in both tokens and pays the Treasury exactly 9.5% of each
	///      (a cut can round to 0 on cbBTC's ~0.009% fee at these sizes, so it's checked against the event, not > 0).
	function _tradeAndHarvest(ClmPoolDeployerV2.PoolConfig memory cfg, FrostyClmStrategyV2 strategy, uint256 amount0) internal {
		IAeroPoolConfig pool = IAeroPoolConfig(cfg.pool);
		(address t0, address t1) = (pool.token0(), pool.token1());
		for (uint256 r; r < 3; ++r) {
			_swap(cfg.pool, true, int256(amount0 / 2)); // token0 → token1
			_swap(cfg.pool, false, int256(IERC20(t1).balanceOf(address(this)))); // and back
		}
		skip(uint256(cfg.twapInterval) + 1);
		uint256[2] memory treasury = [IERC20(t0).balanceOf(TREASURY), IERC20(t1).balanceOf(TREASURY)];
		vm.recordLogs();
		strategy.harvest();
		uint256[4] memory fees = _feesCollected(address(strategy)); // got0, got1, perf0, perf1
		assertGt(fees[0], 0, string.concat(cfg.symbol, ': fees in token0'));
		assertGt(fees[1], 0, string.concat(cfg.symbol, ': fees in token1'));
		assertEq(fees[2], fees[0] * PERF_FEE_BPS / 10_000, string.concat(cfg.symbol, ': 9.5% of token0 fees'));
		assertEq(fees[3], fees[1] * PERF_FEE_BPS / 10_000, string.concat(cfg.symbol, ': 9.5% of token1 fees'));
		assertEq(IERC20(t0).balanceOf(TREASURY) - treasury[0], fees[2], string.concat(cfg.symbol, ': the token0 cut paid'));
		assertEq(IERC20(t1).balanceOf(TREASURY) - treasury[1], fees[3], string.concat(cfg.symbol, ': the token1 cut paid'));
	}

	/// @dev The harvest's FeesCollected(got0, got1, perf0, perf1), summed over its emits.
	function _feesCollected(address strategy) internal returns (uint256[4] memory out) {
		Vm.Log[] memory logs = vm.getRecordedLogs();
		for (uint256 i; i < logs.length; ++i) {
			if (logs[i].emitter != strategy || logs[i].topics[0] != FEES_COLLECTED) continue;
			(uint256 a0, uint256 a1, uint256 p0, uint256 p1) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
			out[0] += a0;
			out[1] += a1;
			out[2] += p0;
			out[3] += p1;
		}
	}

	/// @dev Once the harvested fees have unlocked, Alice's whole exit is worth at least what went in.
	function _exitAll(ClmPoolDeployerV2.PoolConfig memory cfg, FrostyClmVault vault, uint256 valueIn) internal {
		IAeroPoolConfig pool = IAeroPoolConfig(cfg.pool);
		(address t0, address t1) = (pool.token0(), pool.token1());
		skip(DURATION);
		uint256[2] memory before = [IERC20(t0).balanceOf(alice), IERC20(t1).balanceOf(alice)];
		vm.prank(alice);
		vault.withdrawAll(0, 0);
		uint256 valueOut = _value0(cfg.pool, IERC20(t0).balanceOf(alice) - before[0], IERC20(t1).balanceOf(alice) - before[1]);
		emit log_named_uint(string.concat(cfg.symbol, ' in, token0'), valueIn);
		emit log_named_uint(string.concat(cfg.symbol, ' out, token0'), valueOut);
		assertGe(valueOut * 1_000, valueIn * 999, string.concat(cfg.symbol, ': the exit pays back what went in'));
	}

	/// @dev deployPool, wired and handed over as the deploy script leaves it: no gauge, the owner's.
	function _deployChecked(ClmPoolDeployerV2.PoolConfig memory cfg)
		internal
		returns (FrostyClmStrategyV2 strategy, FrostyClmVault vault)
	{
		(strategy, vault) = deployer.deployPool(cfg);
		assertEq(address(vault.strategy()), address(strategy), cfg.symbol);
		assertEq(strategy.vault(), address(vault), cfg.symbol);
		assertEq(strategy.pool(), cfg.pool, cfg.symbol);
		assertEq(strategy.positionWidth(), cfg.positionWidth, cfg.symbol);
		assertEq(strategy.maxTickDeviation(), cfg.maxTickDeviation, cfg.symbol);
		assertEq(strategy.owner(), address(this), 'strategy ownership handed to the owner');
		assertEq(vault.owner(), address(this), 'vault ownership handed to the owner');
		(,, address gauge,,) = deployer.deployments(deployer.deploymentCount() - 1);
		assertEq(gauge, address(0), cfg.symbol);
	}

	/// @dev `amount0` plus `amount1` at the pool's price, in token0: amount1 / (sqrtP / 2^96)^2.
	function _value0(address pool, uint256 amount0, uint256 amount1) internal view returns (uint256) {
		(uint160 sqrtP,,,,,) = IAeroPoolConfig(pool).slot0();
		return amount0 + FullMath.mulDiv(FullMath.mulDiv(amount1, 1 << 96, sqrtP), 1 << 96, sqrtP);
	}

	/// @dev Tops `to` up by `amount`: the stand-in mints a B20, any other token is dealt.
	function _give(address token, address to, uint256 amount) internal {
		if (_isB20Stand(token)) B20StandIn(token).mint(to, amount);
		else deal(token, to, IERC20(token).balanceOf(to) + amount);
	}

	function _isB20(address token) internal view returns (bool) {
		return keccak256(token.code) == keccak256(hex'ef') || _isB20Stand(token);
	}

	function _isB20Stand(address token) internal view returns (bool) {
		return keccak256(token.code) == keccak256(type(B20StandIn).runtimeCode);
	}

	function _swap(address pool, bool zeroForOne, int256 amountIn) internal {
		swapping = pool;
		IAeroPoolConfig(pool).swap(
			address(this), zeroForOne, amountIn, zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1, ''
		);
		swapping = address(0);
	}

	/// @dev Pays the pool from this contract's balance, topped up where short.
	function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
		require(msg.sender == swapping, 'not the pool');
		IAeroPoolConfig pool = IAeroPoolConfig(msg.sender);
		if (amount0Delta > 0) _pay(pool.token0(), uint256(amount0Delta));
		if (amount1Delta > 0) _pay(pool.token1(), uint256(amount1Delta));
	}

	function _pay(address token, uint256 amount) private {
		uint256 held = IERC20(token).balanceOf(address(this));
		if (held < amount) _give(token, address(this), amount - held);
		IERC20(token).transfer(msg.sender, amount);
	}

	function _oracleFed(address token) internal view returns (bool) {
		(address aggregator,,,) = IViAssetInfo(VALUE_INTERPRETER).getAssetInfo(token);
		return aggregator != address(0) && IPoolPricedLookup(REGISTRAR_V2).poolPricedAdapter(token) == address(0);
	}
}

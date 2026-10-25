// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

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
///         factory and vault factory: every entry of the config deploys. The seven stock entries (B20 tokens, which only
///         Base's own node runs) trade against a stand-in holding the pool's real reserves (test/utils/B20Fork.sol), and
///         the real token's transfer rules are read from Base for every contract that moves it. The fork block is a
///         Sunday: the stock feeds hold Friday's close while the pools trade.
///         Run: BASE_MAINNET_RPC=<archive url> forge test --match-contract DeployClmV2Fork -vv
contract DeployClmV2ForkTest is B20Fork {
	address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
	address internal constant AERO_CL_FACTORY = 0x9CB220581b91b0C83223012FE69688b92aD07a76;
	address internal constant TREASURY = 0x47b7702a4789912d0dfFDadC07c50395c293fF0A;
	address internal constant VALUE_INTERPRETER = 0x3CDbaBE5Bf4E6cfE10A2A326E0ad31b2d16398D4;
	address internal constant REGISTRAR_V2 = 0x60338a74c63EDeC7EC020cB9208DD234D9a2146F; // the live ClmVaultPriceFeed's registrar
	address internal constant AERO_NFT_MANAGER = 0x4857DB576eE0e45F10525eC59527BfD10beeC60b;
	uint256 internal constant DURATION = 1 days; // StratFeeManagerInitializable.DURATION: harvested fees unlock over it

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

	function test_deployPool_theStockEntries_takeADeposit_harvestFees_andPayItAllBack() public {
		vm.skip(!forked);
		ClmPoolDeployerV2.PoolConfig[] memory pools = script.readPools();
		uint256 deployed;
		for (uint256 i; i < pools.length; ++i) {
			IAeroPoolConfig pool = IAeroPoolConfig(pools[i].pool);
			address stock = pool.token0() == USDC ? pool.token1() : pool.token0();
			if (keccak256(stock.code) != keccak256(hex'ef')) continue; // WETH, cbBTC: test_deployPool_theNonStockEntries
			assertEq(pool.token0(), USDC, pools[i].symbol); // 0x8335… sorts before every 0xb200… B20
			_roundTrip(pools[i], stock);
			++deployed;
		}
		assertEq(deployed, 7);
	}

	/// @dev One stock entry: deploy; the live token lets the pool, the strategy, the vault and the NFT manager move it;
	///      a first deposit of 10,000 USDC and the stock the range takes; trades both ways; a harvest that pays the
	///      Treasury its cut in both tokens; and, once the fees have unlocked, a whole exit worth at least what went in.
	function _roundTrip(ClmPoolDeployerV2.PoolConfig memory cfg, address stock) internal {
		address[] memory holders = new address[](1);
		holders[0] = cfg.pool;
		_standIn(stock, holders);
		(FrostyClmStrategyV2 strategy, FrostyClmVault vault) = deployer.deployPool(cfg);
		address[4] memory movers = [cfg.pool, address(strategy), address(vault), AERO_NFT_MANAGER];
		for (uint256 j; j < movers.length; ++j) {
			assertTrue(_b20Allows(stock, movers[j]), string.concat(cfg.symbol, ': the live token blocks a contract of the flow'));
		}
		assertTrue(vault.isCalm(), string.concat(cfg.symbol, ': calm at the fork block'));

		(uint160 sqrtP,,,,,) = IAeroPoolConfig(cfg.pool).slot0();
		uint256 stockIn = 2 * FullMath.mulDiv(FullMath.mulDiv(10_000e6, sqrtP, 1 << 96), sqrtP, 1 << 96); // twice $10k of it
		deal(USDC, alice, 10_000e6);
		B20StandIn(stock).mint(alice, stockIn);
		vm.startPrank(alice);
		IERC20(USDC).approve(address(vault), type(uint256).max);
		IERC20(stock).approve(address(vault), type(uint256).max);
		vault.deposit(10_000e6, stockIn, 0);
		vm.stopPrank();
		uint256 valueIn = _usdcValue(cfg.pool, 10_000e6 - IERC20(USDC).balanceOf(alice), stockIn - IERC20(stock).balanceOf(alice));
		assertGt(vault.balanceOf(alice), 0, cfg.symbol);
		(uint256 mainId,,) = strategy.positionMain();
		assertEq(IERC721(AERO_NFT_MANAGER).ownerOf(mainId), address(strategy), cfg.symbol);
		skip(uint256(cfg.twapInterval) + 1);

		for (uint256 r; r < 3; ++r) {
			_swap(cfg.pool, true, 5_000e6); // USDC → stock
			_swap(cfg.pool, false, int256(IERC20(stock).balanceOf(address(this)))); // and back
		}
		skip(uint256(cfg.twapInterval) + 1);
		uint256 treasuryUsdc = IERC20(USDC).balanceOf(TREASURY);
		strategy.harvest();
		assertGt(IERC20(USDC).balanceOf(TREASURY), treasuryUsdc, string.concat(cfg.symbol, ': the cut in USDC'));
		assertGt(IERC20(stock).balanceOf(TREASURY), 0, string.concat(cfg.symbol, ': the cut in the stock'));

		skip(DURATION);
		vm.prank(alice);
		vault.withdrawAll(0, 0);
		uint256 valueOut = _usdcValue(cfg.pool, IERC20(USDC).balanceOf(alice), IERC20(stock).balanceOf(alice));
		emit log_named_uint(string.concat(cfg.symbol, ' in, USDC (6 dp)'), valueIn);
		emit log_named_uint(string.concat(cfg.symbol, ' out, USDC (6 dp)'), valueOut);
		assertGe(valueOut * 1_000, valueIn * 999, string.concat(cfg.symbol, ': the exit pays back what went in'));
	}

	/// @dev `usdc` plus `stock` at the pool's price, in USDC (token0): stock / (sqrtP / 2^96)^2.
	function _usdcValue(address pool, uint256 usdc, uint256 stock) internal view returns (uint256) {
		(uint160 sqrtP,,,,,) = IAeroPoolConfig(pool).slot0();
		return usdc + FullMath.mulDiv(FullMath.mulDiv(stock, 1 << 96, sqrtP), 1 << 96, sqrtP);
	}

	function _swap(address pool, bool usdcIn, int256 amountIn) internal {
		swapping = pool;
		IAeroPoolConfig(pool).swap(
			address(this), usdcIn, amountIn, usdcIn ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1, ''
		);
		swapping = address(0);
	}

	function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
		require(msg.sender == swapping, 'not the pool');
		if (amount0Delta > 0) {
			deal(USDC, address(this), uint256(amount0Delta));
			IERC20(USDC).transfer(msg.sender, uint256(amount0Delta));
		}
		if (amount1Delta > 0) IERC20(IAeroPoolConfig(msg.sender).token1()).transfer(msg.sender, uint256(amount1Delta));
	}

	function _oracleFed(address token) internal view returns (bool) {
		(address aggregator,,,) = IViAssetInfo(VALUE_INTERPRETER).getAssetInfo(token);
		return aggregator != address(0) && IPoolPricedLookup(REGISTRAR_V2).poolPricedAdapter(token) == address(0);
	}
}

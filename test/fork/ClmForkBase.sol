// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Test, Vm} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin-4/contracts/token/ERC20/IERC20.sol';
import {FrostyClmStrategy} from '../../contracts/strategies/velodrome/FrostyClmStrategy.sol';
import {FrostyClmStrategyFactory} from '../../contracts/strategies/FrostyClmStrategyFactory.sol';
import {StratFeeManagerInitializable} from '../../contracts/strategies/StratFeeManagerInitializable.sol';
import {FrostyClmVault} from '../../contracts/vault/FrostyClmVault.sol';
import {FrostyClmVaultFactory} from '../../contracts/vault/FrostyClmVaultFactory.sol';
import {TickMath} from '../../contracts/utils/TickMath.sol';
import {MockValueInterpreter} from '../mocks/MockValueInterpreter.sol';

interface ICLPoolLike {
	function token0() external view returns (address);
	function token1() external view returns (address);
	function gauge() external view returns (address);
	function factory() external view returns (address);
	function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, bool);
	function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data)
		external
		returns (int256 amount0, int256 amount1);
}

interface IRealValueInterpreter {
	function calcCanonicalAssetValue(address base, uint256 amount, address quote) external view returns (uint256);
}

/// @notice Shared fork setup: FrostyFi's CLM deployed fresh on Base at BASE_FORK_BLOCK, over non-stock Slipstream-2
///         pools (B20 stock tokens can't run on a fork). Addresses read 2026-10-11 with `cast`.
abstract contract ClmForkBase is Test {
	address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
	address internal constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
	address internal constant WETH = 0x4200000000000000000000000000000000000006;
	address internal constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
	address internal constant NFT_MANAGER = 0xe1f8cd9AC4e4A65F54f38a5CdAfCA44f6dD68b53;
	address internal constant AERO_ROUTER = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;
	address internal constant AERO_POOL_FACTORY = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;
	address internal constant VALUE_INTERPRETER = 0x3CDbaBE5Bf4E6cfE10A2A326E0ad31b2d16398D4;
	address internal constant TREASURY = 0x47b7702a4789912d0dfFDadC07c50395c293fF0A;
	address internal constant VOTER = 0x16613524e02ad97eDfeF371bC883F2F5d6C480A5;
	address internal constant EMERGENCY_COUNCIL = 0x99249b10593fCa1Ae9DAE6D4819F1A6dae5C013D;
	address internal constant POOL_USDC_CBBTC = 0x160D7E9d948B16c163332a277b393c288408eb12; // USDC = token0
	address internal constant GAUGE_USDC_CBBTC = 0x7B0f1103746648FBfce9222f1266f79B934E16b2;
	address internal constant POOL_WETH_USDC = 0x3FE04A59Ebd38cF06080a6F60a98D124eb59392A; // USDC = token1
	address internal constant GAUGE_WETH_USDC = 0xA0B61fdB9f1FB9b917Fe38b49427Fd4D87472D28;
	address internal constant POOL_USDC_AERO = 0xBE00fF35AF70E8415D0eB605a286D8A45466A4c1; // Slipstream-1, AERO = token1
	address internal constant GAUGE_USDC_AERO = 0x430C09546ae9249AB75B9A4ef7B5FD9a4006D6f3;
	uint256 internal constant DEFAULT_FORK_BLOCK = 52489276;
	string internal constant STRATEGY_NAME = 'FrostyClmStrategy-v1';

	address internal keeper = makeAddr('keeper');
	address internal rebalancer = makeAddr('rebalancer');
	address internal alice = makeAddr('alice');
	address internal bob = makeAddr('bob');

	bool internal forked;
	MockValueInterpreter internal vi;
	FrostyClmStrategyFactory internal strategyFactory;
	FrostyClmVaultFactory internal vaultFactory;
	FrostyClmStrategy internal strategy;
	FrostyClmVault internal vault;
	address internal pool;

	/// @dev Forks Base and deploys the factories. Without BASE_MAINNET_RPC every test calls vm.skip(true).
	function _setUpFork() internal {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		vm.createSelectFork(rpc, vm.envOr('BASE_FORK_BLOCK', DEFAULT_FORK_BLOCK));
		forked = true;

		// The real VI's AERO price at the fork block, before any time is skipped.
		vi = new MockValueInterpreter();
		vi.setRate(AERO, USDC, IRealValueInterpreter(VALUE_INTERPRETER).calcCanonicalAssetValue(AERO, 1e18, USDC));

		strategyFactory = new FrostyClmStrategyFactory(keeper, TREASURY, address(vi), 950);
		strategyFactory.addStrategy(STRATEGY_NAME, address(new FrostyClmStrategy()));
		strategyFactory.addRebalancer(rebalancer);
		vaultFactory = new FrostyClmVaultFactory(address(0));
	}

	function _deployVault(address pool_, address gauge, int24 width, int56 deviation) internal {
		pool = pool_;
		strategy = FrostyClmStrategy(payable(strategyFactory.createStrategy(STRATEGY_NAME)));
		vault = vaultFactory.cloneVault();
		vault.initialize(address(strategy), 'FrostyFi CLM test', 'fcTEST');
		strategy.initialize(
			pool_,
			NFT_MANAGER,
			gauge,
			AERO,
			width,
			AERO_POOL_FACTORY,
			USDC,
			StratFeeManagerInitializable.CommonAddresses({
				vault: address(vault),
				unirouter: AERO_ROUTER,
				strategist: address(this),
				factory: address(strategyFactory)
			})
		);
		strategy.setDeviation(deviation);
	}

	/// @dev Lets time pass with no swaps: the pool's TWAP converges on the current tick (calm), and the gauge's minimum
	///      stake time (30 s on the test pools) runs out.
	function _settle() internal {
		skip(uint256(strategy.twapInterval()) + 1);
	}

	/// @dev Deposits up to `amount0`/`amount1` for `user` (the vault takes what the ratio allows) and returns the shares.
	function _deposit(address user, uint256 amount0, uint256 amount1) internal returns (uint256 shares) {
		(address token0, address token1) = vault.wants();
		_fund(token0, user, amount0);
		_fund(token1, user, amount1);
		vm.startPrank(user);
		IERC20(token0).approve(address(vault), amount0);
		IERC20(token1).approve(address(vault), amount1);
		uint256 before = vault.balanceOf(user);
		vault.deposit(amount0, amount1, 0);
		shares = vault.balanceOf(user) - before;
		vm.stopPrank();
	}

	/// @dev USDC and WETH via `deal`; anything else (cbBTC) is bought in the test pool with dealt USDC, then the pool
	///      settles, so the swap's price move doesn't trip the calm check.
	function _fund(address token, address to, uint256 amount) internal {
		if (token == USDC || token == WETH) {
			deal(token, to, IERC20(token).balanceOf(to) + amount);
			return;
		}
		bool zeroForOne = ICLPoolLike(pool).token1() == token;
		ICLPoolLike(pool).swap(
			to,
			zeroForOne,
			-int256(amount),
			zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1,
			abi.encode(pool)
		);
		_settle();
	}

	/// @dev Moves the pool's tick by about `ticks` by selling token0 (ticks < 0) or token1 (ticks > 0).
	function _pushPrice(int24 ticks) internal {
		(, int24 tick,,,,) = ICLPoolLike(pool).slot0();
		ICLPoolLike(pool).swap(
			address(this), ticks < 0, type(int128).max, TickMath.getSqrtRatioAtTick(tick + ticks), abi.encode(pool)
		);
	}

	function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
		address pool_ = abi.decode(data, (address));
		require(msg.sender == pool_, 'not the pool');
		if (amount0Delta > 0) _pay(ICLPoolLike(pool_).token0(), uint256(amount0Delta));
		if (amount1Delta > 0) _pay(ICLPoolLike(pool_).token1(), uint256(amount1Delta));
	}

	function _pay(address token, uint256 amount) private {
		require(token == USDC || token == WETH, 'only USDC and WETH can be dealt');
		deal(token, address(this), amount);
		IERC20(token).transfer(msg.sender, amount);
	}

	/// @dev Sums the `amount` of every `event(…, uint256 amount)` log `emitter` sent with `topic0`.
	function _sumLogs(Vm.Log[] memory logs, address emitter, bytes32 topic0) internal pure returns (uint256 sum) {
		for (uint256 i; i < logs.length; ++i) {
			if (logs[i].emitter == emitter && logs[i].topics[0] == topic0) {
				sum += abi.decode(logs[i].data, (uint256));
			}
		}
	}
}

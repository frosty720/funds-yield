// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC20} from '@openzeppelin-4/contracts/token/ERC20/IERC20.sol';
import {Ownable} from '@openzeppelin-4/contracts/access/Ownable.sol';
import {FrostyClmStrategy} from '../../contracts/strategies/velodrome/FrostyClmStrategy.sol';
import {FrostyClmVault} from '../../contracts/vault/FrostyClmVault.sol';
import {StratFeeManagerInitializable} from '../../contracts/strategies/StratFeeManagerInitializable.sol';
import {FrostyClmStrategyV2Mock} from '../mocks/FrostyClmStrategyV2Mock.sol';
import {ClmForkBase} from './ClmForkBase.sol';

interface IVoterLike {
	function killGauge(address gauge) external;
	function isAlive(address gauge) external view returns (bool);
}

/// @notice Beefy's vault and strategy behaviour that FrostyFi relies on, after the FrostyFi changes.
///         Run: BASE_MAINNET_RPC=<archive url> forge test --match-contract FrostyClmLifecycleFork -vv
contract FrostyClmLifecycleForkTest is ClmForkBase {
	function setUp() public {
		_setUpFork();
		if (!forked) return;
		_deployVault(POOL_USDC_CBBTC, GAUGE_USDC_CBBTC, 4, 5); // narrow (±200 ticks) so a test swap can leave the range
		_settle();
	}

	function test_depositWithdraw_proRata() public {
		vm.skip(!forked);
		uint256 aliceShares = _deposit(alice, 20_000e6, 0.2e8);
		_settle();
		uint256 bobShares = _deposit(bob, 10_000e6, 0.1e8);
		_settle();

		(uint256 bal0, uint256 bal1) = vault.balances();
		uint256 supply = vault.totalSupply();
		vm.prank(alice);
		vault.withdraw(aliceShares, 0, 0);
		uint256 got0 = IERC20(USDC).balanceOf(alice);
		uint256 got1 = IERC20(CBBTC).balanceOf(alice);
		assertApproxEqRel(got0, bal0 * aliceShares / supply, 1e15, 'USDC within 0.1% of the pro-rata share');
		assertApproxEqRel(got1, bal1 * aliceShares / supply, 1e15, 'cbBTC within 0.1% of the pro-rata share');
		assertEq(vault.balanceOf(bob), bobShares);
	}

	function test_withdraw_enforcesTheMinimums() public {
		vm.skip(!forked);
		uint256 shares = _deposit(alice, 20_000e6, 0.2e8);
		_settle();
		vm.prank(alice);
		vm.expectRevert(FrostyClmVault.TooMuchSlippage.selector);
		vault.withdraw(shares, type(uint256).max, 0);
	}

	function test_moveTicks_rebalancerOnlyAndRecentres() public {
		vm.skip(!forked);
		_deposit(alice, 20_000e6, 0.2e8);
		_pushPrice(-400); // sell USDC: the tick drops out of the ±200-tick main range
		_settle();
		(, int24 lowerBefore, int24 upperBefore) = strategy.positionMain();
		int24 tick = strategy.currentTick();
		assertTrue(tick < lowerBefore || tick >= upperBefore, 'out of range');

		vm.prank(alice);
		vm.expectRevert(FrostyClmStrategy.NotAuthorized.selector);
		strategy.moveTicks();

		vm.prank(rebalancer);
		strategy.moveTicks();
		(, int24 lower, int24 upper) = strategy.positionMain();
		assertTrue(lower <= tick && tick < upper, 'recentred on the current tick');
	}

	function test_moveTicks_refusedWhileNotCalm() public {
		vm.skip(!forked);
		_deposit(alice, 20_000e6, 0.2e8);
		_settle();
		_pushPrice(-400);
		vm.prank(rebalancer);
		vm.expectRevert(FrostyClmStrategy.NotCalm.selector);
		strategy.moveTicks();
	}

	function test_panic_withdrawSkipsCalmAndDelay() public {
		vm.skip(!forked);
		uint256 shares = _deposit(alice, 20_000e6, 0.2e8);
		_pushPrice(-400); // not calm, and still inside the action delay
		skip(1); // a withdrawal in the deposit's own block must be calm even when paused (Beefy's same-block guard)
		vm.prank(alice);
		vm.expectRevert(); // ActionLocked or NotCalm: either blocks a normal exit
		vault.withdraw(shares, 0, 0);

		vm.prank(keeper); // the factory's keeper is a manager
		strategy.panic(0, 0);
		vm.prank(alice);
		vault.withdraw(shares, 0, 0);
		assertGt(IERC20(USDC).balanceOf(alice) + IERC20(CBBTC).balanceOf(alice), 0);
	}

	function test_panic_harvestReverts() public {
		vm.skip(!forked);
		_deposit(alice, 20_000e6, 0.2e8);
		skip(1 days);
		vm.prank(keeper);
		strategy.panic(0, 0);
		vm.expectRevert(StratFeeManagerInitializable.StrategyPaused.selector);
		strategy.harvest();
	}

	function test_killedGauge_withdrawWorksAfterPanic() public {
		vm.skip(!forked);
		uint256 shares = _deposit(alice, 20_000e6, 0.2e8);
		_settle();
		vm.prank(EMERGENCY_COUNCIL);
		IVoterLike(VOTER).killGauge(GAUGE_USDC_CBBTC);
		assertFalse(IVoterLike(VOTER).isAlive(GAUGE_USDC_CBBTC));

		vm.prank(alice);
		vm.expectRevert(bytes('GK')); // the withdrawal re-stakes what's left, and a dead gauge refuses deposits
		vault.withdraw(shares / 2, 0, 0);
		vm.expectRevert(bytes('GK'));
		strategy.harvest();

		vm.prank(keeper);
		strategy.panic(0, 0); // claim and withdraw from the gauge still work on a killed gauge
		vm.prank(alice);
		vault.withdraw(shares, 0, 0);
		assertEq(vault.balanceOf(alice), 0);
	}

	function test_upgrade_keepsStateAndIsOwnerOnly() public {
		vm.skip(!forked);
		_deposit(alice, 20_000e6, 0.2e8);
		_settle();
		(uint256 bal0, uint256 bal1) = vault.balances();
		(uint256 nftId, int24 lower, int24 upper) = strategy.positionMain();
		address next = address(new FrostyClmStrategyV2Mock());

		vm.prank(keeper);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
		strategyFactory.upgradeTo(STRATEGY_NAME, next);

		strategyFactory.upgradeTo(STRATEGY_NAME, next);
		assertEq(FrostyClmStrategyV2Mock(payable(address(strategy))).version(), 2);
		(uint256 after0, uint256 after1) = vault.balances();
		(uint256 nftAfter, int24 lowerAfter, int24 upperAfter) = strategy.positionMain();
		assertEq(after0, bal0);
		assertEq(after1, bal1);
		assertEq(nftAfter, nftId);
		assertEq(lowerAfter, lower);
		assertEq(upperAfter, upper);
		assertEq(strategy.compoundToken(), USDC);
	}

	function test_retireVault_sendsDustToTheTreasury() public {
		vm.skip(!forked);
		uint256 shares = _deposit(alice, 20_000e6, 0.2e8);
		_settle();
		vm.prank(alice);
		vault.withdraw(shares, 0, 0);
		assertEq(vault.totalSupply(), 10 ** 3, 'only the burned minimum shares remain');

		(uint256 dust0, uint256 dust1) = vault.balances();
		uint256 usdcBefore = IERC20(USDC).balanceOf(TREASURY);
		uint256 btcBefore = IERC20(CBBTC).balanceOf(TREASURY);
		strategy.retireVault();
		assertEq(IERC20(USDC).balanceOf(TREASURY) - usdcBefore, dust0, 'the USDC dust went to the treasury');
		assertEq(IERC20(CBBTC).balanceOf(TREASURY) - btcBefore, dust1, 'the cbBTC dust went to the treasury');
		(uint256 left0, uint256 left1) = strategy.balancesOfThis();
		assertEq(left0 + left1, 0);
		assertEq(strategy.owner(), address(0));
	}

	function test_token1Pool_compoundsIntoUsdc() public {
		vm.skip(!forked);
		_deployVault(POOL_WETH_USDC, GAUGE_WETH_USDC, 30, 5); // USDC is token1 here
		_settle();
		_deposit(alice, 5e18, 15_000e6);
		skip(1 days);
		(uint256 wethBefore, uint256 usdcBefore) = vault.balances();
		strategy.harvest();
		(uint256 wethAfter, uint256 usdcAfter) = vault.balances();
		assertGt(usdcAfter, usdcBefore, 'the sale landed on the USDC side');
		assertApproxEqAbs(wethAfter, wethBefore, 1);
	}
}

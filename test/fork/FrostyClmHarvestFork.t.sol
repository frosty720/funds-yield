// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Vm} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin-4/contracts/token/ERC20/IERC20.sol';
import {FrostyClmStrategy} from '../../contracts/strategies/velodrome/FrostyClmStrategy.sol';
import {StratFeeManagerInitializable} from '../../contracts/strategies/StratFeeManagerInitializable.sol';
import {MockValueInterpreter} from '../mocks/MockValueInterpreter.sol';
import {ClmForkBase} from './ClmForkBase.sol';

/// @notice FrostyFi's fee and compounding changes, on USDC/cbBTC (USDC is token0, as in the stock pools).
///         Run: BASE_MAINNET_RPC=<archive url> forge test --match-contract FrostyClmHarvestFork -vv
contract FrostyClmHarvestForkTest is ClmForkBase {
	bytes32 internal constant CLAIMED = keccak256('ClaimedRewards(uint256)');
	bytes32 internal constant FEE_PAID = keccak256('PerformanceFeePaid(address,uint256)');
	bytes32 internal constant COMPOUNDED = keccak256('Compounded(uint256,uint256)');
	/// @dev StratFeeManagerInitializable.DURATION (internal): how long a harvest's proceeds stay locked.
	uint256 internal constant LOCK_DURATION = 1 days;

	function setUp() public {
		_setUpFork();
		if (!forked) return;
		_deployVault(POOL_USDC_CBBTC, GAUGE_USDC_CBBTC, 30, 5);
		_settle();
		_deposit(alice, 50_000e6, 0.5e8);
	}

	function test_harvest_paysTheFeeAndCompoundsTheRest() public {
		vm.skip(!forked);
		skip(1 days);
		(uint256 usdcBefore, uint256 btcBefore) = vault.balances();
		uint256 treasuryBefore = IERC20(AERO).balanceOf(TREASURY);

		vm.recordLogs();
		vm.prank(keeper); // the keeper or the owner (final review I2)
		strategy.harvest();
		Vm.Log[] memory logs = vm.getRecordedLogs();

		uint256 claimed = _sumLogs(logs, address(strategy), CLAIMED);
		uint256 fee = _sumLogs(logs, address(strategy), FEE_PAID);
		assertGt(claimed, 0, 'the gauge paid AERO');
		assertEq(fee, claimed * 950 / 10_000, '9.5% of every claim');
		assertEq(IERC20(AERO).balanceOf(TREASURY) - treasuryBefore, fee);
		assertEq(strategy.fees(), 0, 'all AERO sold');
		assertEq(IERC20(AERO).balanceOf(address(strategy)), 0);

		(uint256 sold, uint256 received) = _compounded(logs);
		assertEq(sold, claimed - fee);
		uint256 fair = vi.calcCanonicalAssetValue(AERO, sold, USDC);
		assertGe(received, fair * 9800 / 10_000, 'within MAX_SALE_SLIPPAGE_BPS of the VI');

		// Removing and re-adding liquidity rounds down by a few wei per position.
		(uint256 usdcAfter, uint256 btcAfter) = vault.balances();
		assertApproxEqAbs(usdcAfter, usdcBefore, 10, 'the compounded USDC is locked at first (final review I1)');
		assertApproxEqAbs(btcAfter, btcBefore, 10, 'no cbBTC moved');
		assertEq(strategy.lastHarvest(), block.timestamp);
		skip(LOCK_DURATION);
		(usdcAfter,) = vault.balances();
		assertApproxEqAbs(usdcAfter, usdcBefore + received, 10, 'all of it reaches the share price after the lock');
	}

	function test_harvest_strangerCannotHarvest() public {
		vm.skip(!forked);
		skip(1 days);
		vm.prank(bob);
		vm.expectRevert(StratFeeManagerInitializable.NotManager.selector);
		strategy.harvest();
	}

	function test_harvest_releasesTheProceedsLinearly() public {
		vm.skip(!forked);
		skip(1 days);
		(uint256 usdcBefore,) = vault.balances();
		vm.recordLogs();
		strategy.harvest();
		(, uint256 received) = _compounded(vm.getRecordedLogs());
		assertGt(received, 0);
		skip(LOCK_DURATION / 2);
		(uint256 usdcHalf,) = vault.balances();
		assertApproxEqAbs(usdcHalf, usdcBefore + received / 2, 10, 'half released at half the lock');
	}

	/// @dev Final review I1: Bob deposits just before a harvest and leaves right after. He must not walk off with his
	///      pro-rata share of the AERO the vault earned before he arrived.
	function test_jitDeposit_takesNoShareOfEarlierYield() public {
		vm.skip(!forked);
		skip(1 days);
		uint256 shares = _deposit(bob, 50_000e6, 0.5e8);
		uint256 kept0 = IERC20(USDC).balanceOf(bob);
		uint256 kept1 = IERC20(CBBTC).balanceOf(bob);
		int256 in0 = int256(50_000e6) - int256(kept0);
		int256 in1 = int256(0.5e8) - int256(kept1);
		_settle();
		vm.recordLogs();
		strategy.harvest();
		(, uint256 received) = _compounded(vm.getRecordedLogs());
		uint256 bobProRata = received * shares / vault.totalSupply();
		_settle();
		vm.prank(bob);
		vault.withdraw(shares, 0, 0);
		int256 out0 = int256(IERC20(USDC).balanceOf(bob)) - int256(kept0);
		int256 out1 = int256(IERC20(CBBTC).balanceOf(bob)) - int256(kept1);
		// Bob's gain in USDC (token0) units, at the pool's price: cbBTC raw × 1e36 / price.
		int256 gain = (out0 - in0) + (out1 - in1) * 1e36 / int256(strategy.price());
		assertLt(gain, int256(bobProRata / 100), 'under 1% of what an unlocked harvest would hand him');
	}

	function test_harvest_readsTheFeeFromTheFactory() public {
		vm.skip(!forked);
		strategyFactory.setPerfFeeBps(2500);
		skip(1 days);
		vm.recordLogs();
		strategy.harvest();
		Vm.Log[] memory logs = vm.getRecordedLogs();
		uint256 claimed = _sumLogs(logs, address(strategy), CLAIMED);
		assertEq(_sumLogs(logs, address(strategy), FEE_PAID), claimed * 2500 / 10_000);
	}

	function test_harvest_waitsForTheActionDelay() public {
		vm.skip(!forked);
		skip(1 days);
		_deposit(bob, 1_000e6, 0.01e8); // re-stakes: the gauge's 30 s minimum stake time restarts
		vm.expectRevert(abi.encodeWithSelector(FrostyClmStrategy.ActionLocked.selector, strategy.actionableAt()));
		strategy.harvest();
	}

	function test_harvest_refusesASaleBelowTheOracle() public {
		vm.skip(!forked);
		skip(1 days);
		uint256 rate = vi.rate(AERO, USDC);
		vi.setRate(AERO, USDC, rate * 110 / 100); // VI 10% above the pool: the minimum can't be met
		vm.expectRevert();
		strategy.harvest();
	}

	function test_harvest_staleOracle_revertsAndChangesNothing() public {
		vm.skip(!forked);
		skip(1 days);
		vi.setReverting(true);
		uint256 treasuryBefore = IERC20(AERO).balanceOf(TREASURY);
		vm.expectRevert(MockValueInterpreter.MockStalePrice.selector);
		strategy.harvest();
		assertEq(IERC20(AERO).balanceOf(TREASURY), treasuryBefore);
		assertEq(strategy.fees(), 0);
	}

	function test_harvest_dust_carriesOverWithoutDoubleFee() public {
		vm.skip(!forked);
		uint256 rate = vi.rate(AERO, USDC);
		skip(1 days);
		vi.setRate(AERO, USDC, 0); // the oracle values the AERO at 0 USDC: too little to sell
		vm.recordLogs();
		strategy.harvest();
		Vm.Log[] memory first = vm.getRecordedLogs();
		uint256 carried = strategy.fees();
		assertGt(carried, 0, 'carried to the next harvest');
		assertEq(IERC20(AERO).balanceOf(address(strategy)), carried);
		(uint256 sold,) = _compounded(first);
		assertEq(sold, 0, 'nothing sold');

		vi.setRate(AERO, USDC, rate);
		skip(1 days);
		strategy.harvest();
		Vm.Log[] memory second = vm.getRecordedLogs();
		(sold,) = _compounded(second);
		uint256 claimedSecond = _sumLogs(second, address(strategy), CLAIMED);
		uint256 feeSecond = _sumLogs(second, address(strategy), FEE_PAID);
		assertEq(feeSecond, claimedSecond * 950 / 10_000, 'the carried AERO is not charged again');
		assertEq(sold, carried + claimedSecond - feeSecond);
		assertEq(strategy.fees(), 0);
	}

	function test_initialize_refusesAMismatchedSetup() public {
		vm.skip(!forked);
		StratFeeManagerInitializable.CommonAddresses memory common = StratFeeManagerInitializable.CommonAddresses({
			vault: address(vault),
			unirouter: AERO_ROUTER,
			strategist: address(this),
			factory: address(strategyFactory)
		});

		FrostyClmStrategy s = FrostyClmStrategy(payable(strategyFactory.createStrategy(STRATEGY_NAME)));
		vm.expectRevert(FrostyClmStrategy.InvalidInput.selector); // the gauge pays AERO, not USDC
		s.initialize(POOL_USDC_CBBTC, NFT_MANAGER, GAUGE_USDC_CBBTC, USDC, 30, AERO_POOL_FACTORY, USDC, common);

		// USDC/AERO (Slipstream-1, ts2000): its gauge pays AERO, which is also one of its tokens.
		vm.expectRevert(FrostyClmStrategy.InvalidInput.selector);
		s.initialize(POOL_USDC_AERO, NFT_MANAGER, GAUGE_USDC_AERO, AERO, 30, AERO_POOL_FACTORY, USDC, common);

		vm.expectRevert(FrostyClmStrategy.InvalidInput.selector); // compound token not in the pool
		s.initialize(POOL_USDC_CBBTC, NFT_MANAGER, GAUGE_USDC_CBBTC, AERO, 30, AERO_POOL_FACTORY, WETH, common);

		vm.expectRevert(FrostyClmStrategy.InvalidInput.selector); // no route factory
		s.initialize(POOL_USDC_CBBTC, NFT_MANAGER, GAUGE_USDC_CBBTC, AERO, 30, address(0), USDC, common);

		vm.expectRevert(FrostyClmStrategy.InvalidInput.selector); // another pool's gauge
		s.initialize(POOL_USDC_CBBTC, NFT_MANAGER, GAUGE_WETH_USDC, AERO, 30, AERO_POOL_FACTORY, USDC, common);
	}

	function test_setSwapRoute_ownerOnlyAndChecked() public {
		vm.skip(!forked);
		vm.prank(bob);
		vm.expectRevert('Ownable: caller is not the owner');
		strategy.setSwapRoute(AERO_POOL_FACTORY, USDC);

		vm.expectRevert(FrostyClmStrategy.InvalidInput.selector);
		strategy.setSwapRoute(AERO_POOL_FACTORY, WETH);

		strategy.setSwapRoute(AERO_POOL_FACTORY, CBBTC);
		assertEq(strategy.compoundToken(), CBBTC);
		assertEq(strategy.routeFactory(), AERO_POOL_FACTORY);
	}

	/// @dev The single Compounded(sold, received) log, or (0, 0) when the harvest sold nothing.
	function _compounded(Vm.Log[] memory logs) internal view returns (uint256 sold, uint256 received) {
		for (uint256 i; i < logs.length; ++i) {
			if (logs[i].emitter == address(strategy) && logs[i].topics[0] == COMPOUNDED) {
				(sold, received) = abi.decode(logs[i].data, (uint256, uint256));
			}
		}
	}
}

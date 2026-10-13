// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC20} from '@openzeppelin-4/contracts/token/ERC20/IERC20.sol';
import {FrostyClmStrategy} from '../../contracts/strategies/velodrome/FrostyClmStrategy.sol';
import {ClmForkBase, IRealValueInterpreter} from './ClmForkBase.sol';

/// @notice FrostyFi's CLM on a Slipstream-1 pool without USDC (WETH/cbLTC). Older CLGauge: no minimum stake time,
///         no early-claim penalty, and its factory has no minStakeTimes (plan 1b, 2026-10-13).
contract FrostyClmSlipstream1ForkTest is ClmForkBase {
	address internal constant S1_NFT_MANAGER = 0x827922686190790b37229fd06084350E74485b72;
	address internal constant POOL_WETH_CBLTC = 0x200681425b0C8D78C6a467512C5D49FA56BaC88A;
	address internal constant GAUGE_WETH_CBLTC = 0x88040de1F5811090b638Fa70633B24a3e319D06f;

	function setUp() public {
		_setUpFork();
		if (!forked) return;
		vi.setRate(AERO, WETH, IRealValueInterpreter(VALUE_INTERPRETER).calcCanonicalAssetValue(AERO, 1e18, WETH));
		_deployVaultOn(POOL_WETH_CBLTC, GAUGE_WETH_CBLTC, S1_NFT_MANAGER, WETH, 8, 20);
		_settle();
	}

	function _depositEven(address user, uint256 weth) internal returns (uint256) {
		// cbLTC (raw) per WETH (raw) × 1e36 is the strategy's price: an even split at the pool's price.
		return _deposit(user, weth, weth * strategy.price() / 1e36);
	}

	function test_minActionDelay_isZeroOnAnOlderGauge() public {
		vm.skip(!forked);
		assertEq(strategy.minActionDelay(), 0);
	}

	function test_slipstream1_depositHarvestWithdraw() public {
		vm.skip(!forked);
		uint256 shares = _depositEven(alice, 5e18);
		assertGt(shares, 0);
		skip(1 days);
		(uint256 wethBefore,) = vault.balances();
		vm.prank(keeper);
		strategy.harvest(); // AERO sold into WETH on the basic AERO/WETH pool
		skip(1 days); // the proceeds unlock over a day
		(uint256 wethAfter,) = vault.balances();
		assertGt(wethAfter, wethBefore, 'the AERO came back as WETH');

		vm.prank(alice);
		vault.withdraw(shares, 0, 0);
		assertGt(IERC20(WETH).balanceOf(alice), 0);
		assertGt(IERC20(0xcb17C9Db87B595717C857a08468793f5bAb6445F).balanceOf(alice), 0);
	}
}

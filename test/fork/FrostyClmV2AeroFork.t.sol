// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Test, Vm} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin-4/contracts/token/ERC20/IERC20.sol';
import {IERC721} from '@openzeppelin-4/contracts/token/ERC721/IERC721.sol';
import {FrostyClmStrategyV2} from '../../contracts/strategies/aero/FrostyClmStrategyV2.sol';
import {FrostyClmStrategyFactory} from '../../contracts/strategies/FrostyClmStrategyFactory.sol';
import {StratFeeManagerInitializable} from '../../contracts/strategies/StratFeeManagerInitializable.sol';
import {FrostyClmVault} from '../../contracts/vault/FrostyClmVault.sol';
import {FrostyClmVaultFactory} from '../../contracts/vault/FrostyClmVaultFactory.sol';
import {ClmPoolDeployerV2} from '../../contracts/deploy/ClmPoolDeployerV2.sol';
import {TickMath} from '../../contracts/utils/TickMath.sol';
import {MockValueInterpreter} from '../mocks/MockValueInterpreter.sol';

interface IAeroPool {
	function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, bool);
	function tickSpacing() external view returns (int24);
	function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data)
		external
		returns (int256 amount0, int256 amount1);
}

/// @notice FrostyClmStrategyV2 on Aero's Slipstream (FrostyFi 2026-10-25): deployed fresh on Base after the Aero upgrade
///         over Aero's WETH/USDC pool (B20 stock tokens can't run on a fork). The vault never stakes; a harvest collects
///         the positions' trading fees, pays the 9.5% fee in both tokens and compounds the rest.
///         Run: BASE_MAINNET_RPC=<archive url> forge test --match-contract FrostyClmV2AeroFork -vv
contract FrostyClmV2AeroForkTest is Test {
	// Aero (Dromos-Labs metadex-slipstream-public deployment-addresses/cl-base.json, checked on chain 2026-10-25)
	address internal constant AERO_NFT_MANAGER = 0x4857DB576eE0e45F10525eC59527BfD10beeC60b;
	address internal constant POOL = 0x4A7af46bC8aBc00048c6c7920a1488DAF568366c; // WETH/USDC 0.04%, tick spacing 50
	// Aerodrome's (pre-upgrade) Slipstream-2 WETH/USDC pool and its NFT manager
	address internal constant OLD_POOL = 0x3FE04A59Ebd38cF06080a6F60a98D124eb59392A;
	address internal constant OLD_NFT_MANAGER = 0xe1f8cd9AC4e4A65F54f38a5CdAfCA44f6dD68b53;
	address internal constant WETH = 0x4200000000000000000000000000000000000006; // token0
	address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // token1
	address internal constant TREASURY = 0x47b7702a4789912d0dfFDadC07c50395c293fF0A;
	uint256 internal constant FORK_BLOCK = 53_075_000; // 2026-10-25, three days after the upgrade
	string internal constant STRATEGY_NAME = 'FrostyClmStrategy-v2';
	uint256 internal constant PERF_FEE_BPS = 950;
	uint256 internal constant DURATION = 1 days; // StratFeeManagerInitializable.DURATION (internal)
	int24 internal constant WIDTH = 10; // × tick spacing 50 = 500 ticks a side, about ±5%
	int24 internal constant PUSH = 300; // past _config's 250-tick calm deviation, inside the 500-tick range

	bytes32 internal constant FEES_COLLECTED = keccak256('FeesCollected(uint256,uint256,uint256,uint256)');
	bytes32 internal constant COMPOUNDED = keccak256('Compounded(uint256,uint256)');

	address internal keeper = makeAddr('keeper');
	address internal rebalancer = makeAddr('rebalancer');
	address internal alice = makeAddr('alice');
	address internal bob = makeAddr('bob');

	bool internal forked;
	FrostyClmStrategyFactory internal strategyFactory;
	FrostyClmVaultFactory internal vaultFactory;
	ClmPoolDeployerV2 internal deployer;
	FrostyClmStrategyV2 internal strategy;
	FrostyClmVault internal vault;

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		vm.createSelectFork(rpc, vm.envOr('BASE_FORK_BLOCK_AERO', FORK_BLOCK));
		// Aero's swap hook (the pool's fee()) uses Cancun opcodes; our code still compiles for paris (Beefy's settings)
		vm.setEvmVersion('cancun');
		forked = true;

		strategyFactory = new FrostyClmStrategyFactory(keeper, TREASURY, address(new MockValueInterpreter()), PERF_FEE_BPS);
		strategyFactory.addStrategy(STRATEGY_NAME, address(new FrostyClmStrategyV2()));
		strategyFactory.addRebalancer(rebalancer);
		vaultFactory = new FrostyClmVaultFactory(address(0));
		deployer = new ClmPoolDeployerV2(strategyFactory, vaultFactory, address(this));
		(strategy, vault) = deployer.deployPool(_config(POOL, USDC));
	}

	// ─── deploying ────────────────────────────────────────────────────────────────────────────────────────────────────

	function test_deployer_wiresAnAeroPoolWithNoGauge() public {
		vm.skip(!forked);
		assertEq(strategy.pool(), POOL);
		assertEq(strategy.nftManager(), AERO_NFT_MANAGER);
		assertEq(strategy.compoundToken(), USDC);
		assertEq(strategy.positionWidth(), WIDTH);
		assertEq(strategy.owner(), address(this));
		assertEq(address(vault.strategy()), address(strategy));
		(string memory symbol, address pool, address gauge, address strat, address vlt) = deployer.deployments(0);
		assertEq(symbol, 'WETH-USDC');
		assertEq(pool, POOL);
		assertEq(gauge, address(0));
		assertEq(strat, address(strategy));
		assertEq(vlt, address(vault));
		assertEq(strategy.actionableAt(), 0);
	}

	function test_deployer_refusesPreUpgradePoolsAndForeignCompoundTokens() public {
		vm.skip(!forked);
		vm.expectRevert(abi.encodeWithSelector(ClmPoolDeployerV2.WrongPool.selector, 'WETH-USDC'));
		deployer.deployPool(_config(OLD_POOL, USDC));
		vm.expectRevert(abi.encodeWithSelector(ClmPoolDeployerV2.WrongPool.selector, 'WETH-USDC'));
		deployer.deployPool(_config(POOL, makeAddr('notAPoolToken')));
		vm.prank(alice);
		vm.expectRevert(ClmPoolDeployerV2.NotOwner.selector);
		deployer.deployPool(_config(POOL, USDC));
	}

	function test_initialize_refusesAnotherFactorysNftManager() public {
		vm.skip(!forked);
		FrostyClmStrategyV2 bare = FrostyClmStrategyV2(payable(strategyFactory.createStrategy(STRATEGY_NAME)));
		vm.expectRevert(FrostyClmStrategyV2.InvalidInput.selector);
		bare.initialize(POOL, OLD_NFT_MANAGER, WIDTH, USDC, _common(address(vault)));
	}

	// ─── never staked ───────────────────────────────────────────────────────────────────────────────────────────────

	function test_deposit_mintsPositionsTheStrategyKeeps() public {
		vm.skip(!forked);
		_deposit(alice, 10 ether, 30_000e6);
		(uint256 mainId,,) = strategy.positionMain();
		(uint256 altId,,) = strategy.positionAlt();
		assertGt(mainId, 0);
		assertEq(IERC721(AERO_NFT_MANAGER).ownerOf(mainId), address(strategy)); // not a gauge's
		if (altId != 0) assertEq(IERC721(AERO_NFT_MANAGER).ownerOf(altId), address(strategy));
		assertGt(vault.balanceOf(alice), 0);
	}

	// ─── fees ───────────────────────────────────────────────────────────────────────────────────────────────────────

	function test_harvest_collectsBothTokensFees_paysTheFeeInKind_andCompoundsTheRest() public {
		vm.skip(!forked);
		_deposit(alice, 10 ether, 30_000e6);
		_trade(8);
		uint256 treasury0 = IERC20(WETH).balanceOf(TREASURY);
		uint256 treasury1 = IERC20(USDC).balanceOf(TREASURY);

		vm.recordLogs();
		vm.prank(keeper);
		strategy.harvest();
		(uint256 got0, uint256 got1, uint256 perf0, uint256 perf1) = _feesCollected(vm.getRecordedLogs());

		assertGt(got0, 0, 'WETH fees from selling WETH');
		assertGt(got1, 0, 'USDC fees from selling USDC');
		assertEq(perf0, got0 * PERF_FEE_BPS / 10_000);
		assertEq(perf1, got1 * PERF_FEE_BPS / 10_000);
		assertEq(IERC20(WETH).balanceOf(TREASURY) - treasury0, perf0, 'the fee is paid in kind');
		assertEq(IERC20(USDC).balanceOf(TREASURY) - treasury1, perf1);
		assertEq(strategy.fees0(), 0);
		assertEq(strategy.fees1(), 0);
		assertEq(strategy.totalLocked0(), 0, 'nothing is locked');
		assertEq(strategy.totalLocked1(), 0);
		assertEq(strategy.lastHarvest(), block.timestamp);
	}

	function test_harvest_reportsTheFeesInUsdc() public {
		vm.skip(!forked);
		_deposit(alice, 10 ether, 30_000e6);
		_trade(8);
		vm.recordLogs();
		vm.prank(keeper);
		strategy.harvest();
		Vm.Log[] memory logs = vm.getRecordedLogs();
		(uint256 got0, uint256 got1, uint256 perf0, uint256 perf1) = _feesCollected(logs);
		uint256 received;
		for (uint256 i; i < logs.length; ++i) {
			if (logs[i].emitter == address(strategy) && logs[i].topics[0] == COMPOUNDED) (, received) = abi.decode(logs[i].data, (uint256, uint256));
		}
		uint256 expected = (got1 - perf1) + (got0 - perf0) * strategy.price() / 1e36;
		assertEq(received, expected, 'net fees, WETH valued at the pool price');
	}

	/// Fees join the share price when collected, and a deposit collects first: the price it pays includes them.
	function test_fees_reachTheSharePriceWhenCollected_nothingIsParkedOrLocked() public {
		vm.skip(!forked);
		_deposit(alice, 10 ether, 30_000e6);
		_trade(8);

		_deposit(bob, 0.01 ether, 30e6);
		assertEq(strategy.fees0() + strategy.fees1(), 0, 'nothing parked');
		(uint256 this0, uint256 this1) = strategy.balancesOfThis();
		assertEq(this0, IERC20(WETH).balanceOf(address(strategy)));
		assertEq(this1, IERC20(USDC).balanceOf(address(strategy)));

		vm.prank(keeper);
		strategy.harvest();
		(uint256 locked0, uint256 locked1) = strategy.lockedProfit();
		assertEq(locked0 + locked1, 0, 'nothing locked');
		(uint256 harvest0, uint256 harvest1) = strategy.balances();
		skip(DURATION);
		(uint256 after0, uint256 after1) = strategy.balances();
		assertApproxEqRel(_value(after0, after1), _value(harvest0, harvest1), 1e15, 'no release a day later');
	}

	/// The subgraph's yield sums Compounded: fees a deposit collects are reported then, not lost to the next harvest.
	function test_everyCollectReportsItsFees() public {
		vm.skip(!forked);
		_deposit(alice, 10 ether, 30_000e6);
		_trade(8);
		vm.recordLogs();
		_deposit(bob, 0.01 ether, 30e6);
		Vm.Log[] memory logs = vm.getRecordedLogs();
		(uint256 got0, uint256 got1, uint256 perf0, uint256 perf1) = _feesCollected(logs);
		uint256 received;
		for (uint256 i; i < logs.length; ++i) {
			if (logs[i].emitter == address(strategy) && logs[i].topics[0] == COMPOUNDED) (, received) = abi.decode(logs[i].data, (uint256, uint256));
		}
		assertGt(received, 0);
		assertEq(received, (got1 - perf1) + (got0 - perf0) * strategy.price() / 1e36);
	}

	/// The red team's YIELD-02: Alice holds while the fees are earned, Bob arrives with the same capital right before the
	/// harvest. Net of Bob's deposit fee (which the vault pays to who already holds), Alice leaves right after the harvest
	/// with the fees she earned, and Bob, whose capital earned nothing, gets none of them.
	function test_fees_stayWithWhoHeldWhileTheyWereEarned() public {
		vm.skip(!forked);
		uint256 aliceShares = _deposit(alice, 10 ether, 30_000e6);
		uint256 aliceIn = _value(10 ether - IERC20(WETH).balanceOf(alice), 30_000e6 - IERC20(USDC).balanceOf(alice));
		_trade(8);

		vm.recordLogs();
		uint256 bobShares = _deposit(bob, 10 ether, 30_000e6);
		Vm.Log[] memory logs = vm.getRecordedLogs();
		uint256 bobIn = _value(10 ether - IERC20(WETH).balanceOf(bob), 30_000e6 - IERC20(USDC).balanceOf(bob));
		(uint256 got0, uint256 got1, uint256 perf0, uint256 perf1) = _feesCollected(logs);
		uint256 earned = _value(got0 - perf0, got1 - perf1);
		uint256 bobFee = _depositFeeValue(logs);
		assertGt(earned, 0, 'Bob deposit collected the fees Alice earned');
		vm.prank(keeper);
		strategy.harvest();

		_settle();
		int256 aliceGain = int256(_exit(alice, aliceShares)) - int256(aliceIn);
		skip(DURATION);
		_settle();
		int256 bobGain = int256(_exit(bob, bobShares)) - int256(bobIn);

		assertGt(aliceGain - int256(bobFee), int256(earned * 8 / 10), 'the earner keeps the fees');
		assertLt(bobGain + int256(bobFee), int256(earned * 2 / 10), 'the late entrant gets none');
	}

	/// @dev FrostyClmVault.Deposit's fee0/fee1, valued at the pool price.
	function _depositFeeValue(Vm.Log[] memory logs) internal view returns (uint256) {
		bytes32 topic = keccak256('Deposit(address,uint256,uint256,uint256,uint256,uint256)');
		for (uint256 i; i < logs.length; ++i) {
			if (logs[i].emitter != address(vault) || logs[i].topics[0] != topic) continue;
			(,,, uint256 fee0, uint256 fee1) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256));
			return _value(fee0, fee1);
		}
		return 0;
	}

	function _exit(address who, uint256 shares) internal returns (uint256) {
		uint256 weth0 = IERC20(WETH).balanceOf(who);
		uint256 usdc0 = IERC20(USDC).balanceOf(who);
		vm.prank(who);
		vault.withdraw(shares, 0, 0);
		return _value(IERC20(WETH).balanceOf(who) - weth0, IERC20(USDC).balanceOf(who) - usdc0);
	}

	function test_withdraw_aWholeExitAfterAHarvest() public {
		vm.skip(!forked);
		uint256 shares = _deposit(alice, 10 ether, 30_000e6);
		_trade(8);
		vm.prank(keeper);
		strategy.harvest();
		skip(DURATION);
		_settle();
		vm.prank(alice);
		vault.withdraw(shares, 0, 0);
		assertEq(vault.balanceOf(alice), 0);
		assertGt(IERC20(WETH).balanceOf(alice) + IERC20(USDC).balanceOf(alice), 0);
	}

	// ─── ranges ─────────────────────────────────────────────────────────────────────────────────────────────────────

	function test_moveTicks_followsThePrice() public {
		vm.skip(!forked);
		_deposit(alice, 10 ether, 30_000e6);
		(, int24 lowerBefore, int24 upperBefore) = strategy.positionMain();
		_pushPrice(upperBefore - _tick() + 100); // out of range above
		_settle();
		vm.prank(rebalancer);
		strategy.moveTicks();
		(uint256 mainId, int24 lower, int24 upper) = strategy.positionMain();
		(uint256 altId,,) = strategy.positionAlt();
		int24 tick = _tick();
		assertTrue(lower <= tick && tick < upper, 'the new range holds the price');
		assertTrue(lower != lowerBefore);
		// out of range above, the vault holds only USDC: no two-sided main position can be minted, so it all sits in
		// the one-sided alt position until the price comes back (Beefy's design)
		assertTrue(mainId != 0 || altId != 0, 'the liquidity is back in the pool');
		if (mainId != 0) assertEq(IERC721(AERO_NFT_MANAGER).ownerOf(mainId), address(strategy));
		if (altId != 0) assertEq(IERC721(AERO_NFT_MANAGER).ownerOf(altId), address(strategy));
	}

	/// @dev The bug of 2026-10-18: the first deposit of an exactly equal-value pair left the alt ticks at (0,0) and
	///      reverted with no reason (FrostyClmStrategy v1 and Beefy's StrategyPassiveManagerVelodromeV4).
	function test_firstDeposit_ofAnExactTie_works() public {
		vm.skip(!forked);
		uint256 amount0 = 1 ether;
		uint256 amount1 = amount0 * strategy.price() / 1e36; // its value in USDC, to the unit
		_deposit(alice, amount0, amount1);
		(, int24 altLower, int24 altUpper) = strategy.positionAlt();
		assertTrue(altLower != altUpper, 'a real alt range');
		assertGt(vault.balanceOf(alice), 0);
	}

	function test_unpause_ofAnEmptyVault_works() public {
		vm.skip(!forked);
		vm.startPrank(keeper);
		strategy.panic(0, 0);
		strategy.unpause();
		vm.stopPrank();
		assertFalse(strategy.paused());
	}

	function test_panic_thenAWithdrawal() public {
		vm.skip(!forked);
		uint256 shares = _deposit(alice, 10 ether, 30_000e6);
		vm.prank(keeper);
		strategy.panic(0, 0);
		(uint256 mainId,,) = strategy.positionMain();
		assertEq(mainId, 0, 'liquidity out of the pool');
		vm.prank(alice);
		vault.withdraw(shares, 0, 0);
		assertEq(vault.balanceOf(alice), 0);
	}

	// ─── not calm (red-team YIELD-01, 2026-11-06) ───────────────────────────────────────────────────────────────────

	/// A withdrawal pays out whether or not the pool is calm, and never re-adds at a pushed price: what the others own
	/// waits in the strategy until the next calm re-add.
	function test_withdraw_whenNotCalm_paysTheLeaver_andAddsNothingBack() public {
		vm.skip(!forked);
		uint256 shares = _deposit(alice, 10 ether, 30_000e6);
		_deposit(bob, 10 ether, 30_000e6);
		_pushPrice(PUSH);
		assertFalse(strategy.isCalm());
		uint256 weth0 = IERC20(WETH).balanceOf(alice);
		uint256 usdc0 = IERC20(USDC).balanceOf(alice);

		vm.prank(alice);
		vault.withdraw(shares, 0, 0);

		assertEq(vault.balanceOf(alice), 0);
		assertGt(IERC20(WETH).balanceOf(alice) - weth0, 0, 'paid in WETH');
		assertGt(IERC20(USDC).balanceOf(alice) - usdc0, 0, 'and in USDC');
		(uint256 mainId,,) = strategy.positionMain();
		(uint256 altId,,) = strategy.positionAlt();
		assertEq(mainId + altId, 0, 'nothing re-added at the pushed price');
		(uint256 idle0, uint256 idle1) = strategy.balancesOfThis();
		assertGt(idle0, 0, 'Bob still owns WETH, held by the strategy');
		assertGt(idle1, 0, 'and USDC');
	}

	/// Bob's claim per share is what it was before Alice left, plus his share of the fees her withdrawal collected.
	function test_withdraw_whenNotCalm_leavesTheOthersClaimWhole() public {
		vm.skip(!forked);
		uint256 aliceShares = _deposit(alice, 10 ether, 30_000e6);
		uint256 bobShares = _deposit(bob, 10 ether, 30_000e6);
		_pushPrice(PUSH);
		uint256 supply = vault.totalSupply();
		(uint256 before0, uint256 before1) = strategy.balances();

		vm.recordLogs();
		vm.prank(alice);
		vault.withdraw(aliceShares, 0, 0);
		(uint256 got0, uint256 got1, uint256 perf0, uint256 perf1) = _feesCollected(vm.getRecordedLogs());

		uint256 left = vault.totalSupply();
		assertEq(left, supply - aliceShares);
		(uint256 after0, uint256 after1) = strategy.balances();
		assertApproxEqAbs(after0 * bobShares / left, (before0 + got0 - perf0) * bobShares / supply, 10, 'WETH');
		assertApproxEqAbs(after1 * bobShares / left, (before1 + got1 - perf1) * bobShares / supply, 10, 'USDC');
	}

	/// The next calm harvest (the keeper's daily one) puts what waited back in the pool.
	function test_harvest_afterANotCalmWithdrawal_reAddsTheLiquidity() public {
		vm.skip(!forked);
		uint256 shares = _deposit(alice, 10 ether, 30_000e6);
		_deposit(bob, 10 ether, 30_000e6);
		int24 start = _tick();
		_pushPrice(PUSH);
		vm.prank(alice);
		vault.withdraw(shares, 0, 0);

		_pushPrice(start - _tick());
		_settle();
		assertTrue(strategy.isCalm());
		vm.prank(keeper);
		strategy.harvest();

		(uint256 mainId,,) = strategy.positionMain();
		assertGt(mainId, 0, 'back in the pool');
		(uint256 idle0, uint256 idle1) = strategy.balancesOfThis();
		(uint256 all0, uint256 all1) = strategy.balances();
		assertLt(_value(idle0, idle1), _value(all0, all1) / 1000, 'under 0.1% left idle');
	}

	/// The keeper's re-centre of idle tokens (funds-keeper src/clm/upkeep.ts, YIELD-01): once calm, moveTicks puts it all
	/// back on a fresh range, whichever way the price went (a harvest re-adds on the old range, where it may not fit).
	function test_moveTicks_afterANotCalmWithdrawal_reAddsItAll_priceUp() public {
		_reAddAfterANotCalmExit(PUSH);
	}

	function test_moveTicks_afterANotCalmWithdrawal_reAddsItAll_priceDown() public {
		_reAddAfterANotCalmExit(-PUSH);
	}

	function _reAddAfterANotCalmExit(int24 push) internal {
		vm.skip(!forked);
		uint256 shares = _deposit(alice, 10 ether, 30_000e6);
		_deposit(bob, 10 ether, 30_000e6);
		_pushPrice(push);
		vm.prank(alice);
		vault.withdraw(shares, 0, 0);
		_settle();
		assertTrue(strategy.isCalm(), 'calm at the new price');

		vm.prank(rebalancer);
		strategy.moveTicks();

		(uint256 idle0, uint256 idle1) = strategy.balancesOfThis();
		(uint256 all0, uint256 all1) = strategy.balances();
		assertLt(_value(idle0, idle1), _value(all0, all1) / 1000, 'under 0.1% left idle');
	}

	/// Deposits still wait for calm: a deposit adds at the pool's price.
	function test_deposit_whenNotCalm_stillReverts() public {
		vm.skip(!forked);
		_deposit(alice, 10 ether, 30_000e6);
		_pushPrice(PUSH);
		_fundAndApprove(bob, 1 ether, 3_000e6);
		vm.prank(bob);
		vm.expectRevert(FrostyClmStrategyV2.NotCalm.selector);
		vault.deposit(1 ether, 3_000e6, 0);
	}

	/// A withdrawal in the deposit's own block still needs calm (Beefy's guard on a same-block deposit and exit).
	function test_withdraw_inTheBlockOfADeposit_whenNotCalm_stillReverts() public {
		vm.skip(!forked);
		_deposit(alice, 10 ether, 30_000e6);
		_fundAndApprove(bob, 10 ether, 30_000e6);
		vm.prank(bob);
		vault.deposit(10 ether, 30_000e6, 0);
		uint256 shares = vault.balanceOf(bob);
		_pushPrice(PUSH);
		vm.prank(bob);
		vm.expectRevert(FrostyClmStrategyV2.NotCalm.selector);
		vault.withdraw(shares, 0, 0);
	}

	// ─── helpers ────────────────────────────────────────────────────────────────────────────────────────────────────

	function _config(address pool, address compoundToken) internal pure returns (ClmPoolDeployerV2.PoolConfig memory) {
		return ClmPoolDeployerV2.PoolConfig({
			compoundToken: compoundToken,
			maxTickDeviation: 250,
			pool: pool,
			positionWidth: WIDTH,
			symbol: 'WETH-USDC',
			twapInterval: 120
		});
	}

	function _common(address vault_) internal view returns (StratFeeManagerInitializable.CommonAddresses memory) {
		return StratFeeManagerInitializable.CommonAddresses({
			vault: vault_, unirouter: address(0), strategist: address(this), factory: address(strategyFactory)
		});
	}

	/// @dev The pool's TWAP catches up with its tick (calm again) after the strategy's TWAP interval.
	function _settle() internal {
		skip(uint256(strategy.twapInterval()) + 1);
	}

	function _deposit(address user, uint256 amount0, uint256 amount1) internal returns (uint256 shares) {
		deal(WETH, user, IERC20(WETH).balanceOf(user) + amount0);
		deal(USDC, user, IERC20(USDC).balanceOf(user) + amount1);
		vm.startPrank(user);
		IERC20(WETH).approve(address(vault), amount0);
		IERC20(USDC).approve(address(vault), amount1);
		uint256 before = vault.balanceOf(user);
		vault.deposit(amount0, amount1, 0);
		shares = vault.balanceOf(user) - before;
		vm.stopPrank();
		_settle();
	}

	function _fundAndApprove(address user, uint256 amount0, uint256 amount1) internal {
		deal(WETH, user, IERC20(WETH).balanceOf(user) + amount0);
		deal(USDC, user, IERC20(USDC).balanceOf(user) + amount1);
		vm.startPrank(user);
		IERC20(WETH).approve(address(vault), amount0);
		IERC20(USDC).approve(address(vault), amount1);
		vm.stopPrank();
	}

	/// @dev `rounds` of selling 20 WETH, then selling back the USDC it got: fees in both tokens, the price back near
	///      where it started (the range keeps earning).
	function _trade(uint256 rounds) internal {
		for (uint256 i; i < rounds; ++i) {
			(, int256 out1) = IAeroPool(POOL).swap(address(this), true, 20 ether, TickMath.MIN_SQRT_RATIO + 1, '');
			IAeroPool(POOL).swap(address(this), false, -out1, TickMath.MAX_SQRT_RATIO - 1, '');
		}
		_settle();
	}

	function _pushPrice(int24 ticks) internal {
		IAeroPool(POOL).swap(address(this), ticks < 0, type(int128).max, TickMath.getSqrtRatioAtTick(_tick() + ticks), '');
	}

	function _tick() internal view returns (int24 tick) {
		(, tick,,,,) = IAeroPool(POOL).slot0();
	}

	function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
		require(msg.sender == POOL, 'not the pool');
		if (amount0Delta > 0) _pay(WETH, uint256(amount0Delta));
		if (amount1Delta > 0) _pay(USDC, uint256(amount1Delta));
	}

	function _pay(address token, uint256 amount) private {
		deal(token, address(this), IERC20(token).balanceOf(address(this)) + amount);
		IERC20(token).transfer(msg.sender, amount);
	}

	function _feesCollected(Vm.Log[] memory logs) internal view returns (uint256 got0, uint256 got1, uint256 perf0, uint256 perf1) {
		for (uint256 i; i < logs.length; ++i) {
			if (logs[i].emitter == address(strategy) && logs[i].topics[0] == FEES_COLLECTED) {
				(uint256 a0, uint256 a1, uint256 p0, uint256 p1) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
				got0 += a0;
				got1 += a1;
				perf0 += p0;
				perf1 += p1;
			}
		}
	}

	/// @dev USDC value at the pool price.
	function _value(uint256 amount0, uint256 amount1) internal view returns (uint256) {
		return amount1 + amount0 * strategy.price() / 1e36;
	}
}

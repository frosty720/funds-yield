// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Test} from 'forge-std/Test.sol';
import {Ownable} from '@openzeppelin-4/contracts/access/Ownable.sol';
import {FrostyClmStrategyFactory} from '../contracts/strategies/FrostyClmStrategyFactory.sol';

contract ImplementationV1 {
	function version() external pure returns (uint256) {
		return 1;
	}
}

contract ImplementationV2 {
	function version() external pure returns (uint256) {
		return 2;
	}
}

contract FrostyClmStrategyFactoryTest is Test {
	address internal keeper = makeAddr('keeper');
	address internal treasury = makeAddr('treasury');
	address internal valueInterpreter = makeAddr('valueInterpreter');
	address internal stranger = makeAddr('stranger');
	FrostyClmStrategyFactory internal factory;

	function setUp() public {
		factory = new FrostyClmStrategyFactory(keeper, treasury, valueInterpreter, 950);
	}

	function test_constructor_setsEverything() public view {
		assertEq(factory.owner(), address(this));
		assertEq(factory.keeper(), keeper);
		assertEq(factory.treasury(), treasury);
		assertEq(factory.valueInterpreter(), valueInterpreter);
		assertEq(factory.perfFeeBps(), 950);
		assertEq(factory.MIN_PERF_FEE_BPS(), 500);
		assertEq(factory.MAX_PERF_FEE_BPS(), 3000);
	}

	function test_constructor_rejectsZeroAndOutOfBounds() public {
		vm.expectRevert(FrostyClmStrategyFactory.ZeroAddress.selector);
		new FrostyClmStrategyFactory(keeper, address(0), valueInterpreter, 950);
		vm.expectRevert(FrostyClmStrategyFactory.ZeroAddress.selector);
		new FrostyClmStrategyFactory(keeper, treasury, address(0), 950);
		vm.expectRevert(abi.encodeWithSelector(FrostyClmStrategyFactory.PerfFeeOutOfBounds.selector, 499));
		new FrostyClmStrategyFactory(keeper, treasury, valueInterpreter, 499);
		vm.expectRevert(abi.encodeWithSelector(FrostyClmStrategyFactory.PerfFeeOutOfBounds.selector, 3001));
		new FrostyClmStrategyFactory(keeper, treasury, valueInterpreter, 3001);
	}

	function test_setPerfFeeBps_acceptsTheBoundsAndEmits() public {
		vm.expectEmit(address(factory));
		emit FrostyClmStrategyFactory.SetPerfFeeBps(500);
		factory.setPerfFeeBps(500);
		assertEq(factory.perfFeeBps(), 500);
		factory.setPerfFeeBps(3000);
		assertEq(factory.perfFeeBps(), 3000);
	}

	function test_setters_rejectZeroAndOutOfBounds() public {
		vm.expectRevert(abi.encodeWithSelector(FrostyClmStrategyFactory.PerfFeeOutOfBounds.selector, 3001));
		factory.setPerfFeeBps(3001);
		vm.expectRevert(abi.encodeWithSelector(FrostyClmStrategyFactory.PerfFeeOutOfBounds.selector, 499));
		factory.setPerfFeeBps(499);
		vm.expectRevert(FrostyClmStrategyFactory.ZeroAddress.selector);
		factory.setTreasury(address(0));
		vm.expectRevert(FrostyClmStrategyFactory.ZeroAddress.selector);
		factory.setValueInterpreter(address(0));
	}

	function test_setTreasuryAndValueInterpreter_ownerOnly() public {
		address next = makeAddr('next');
		vm.expectEmit(address(factory));
		emit FrostyClmStrategyFactory.SetTreasury(next);
		factory.setTreasury(next);
		assertEq(factory.treasury(), next);
		vm.expectEmit(address(factory));
		emit FrostyClmStrategyFactory.SetValueInterpreter(next);
		factory.setValueInterpreter(next);
		assertEq(factory.valueInterpreter(), next);

		vm.startPrank(stranger);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
		factory.setTreasury(next);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
		factory.setValueInterpreter(next);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
		factory.setPerfFeeBps(1000);
		vm.stopPrank();
	}

	function test_beacon_createAndUpgrade() public {
		address v1 = address(new ImplementationV1());
		vm.prank(keeper); // addStrategy is onlyManager: owner or keeper
		factory.addStrategy('FrostyClmStrategy-v1', v1);
		ImplementationV1 proxy = ImplementationV1(factory.createStrategy('FrostyClmStrategy-v1'));
		assertEq(proxy.version(), 1);
		assertEq(factory.getImplementation('FrostyClmStrategy-v1'), v1);

		vm.expectRevert(FrostyClmStrategyFactory.StratVersionExists.selector);
		factory.addStrategy('FrostyClmStrategy-v1', v1);

		address v2 = address(new ImplementationV2());
		vm.prank(stranger);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
		factory.upgradeTo('FrostyClmStrategy-v1', v2);
		vm.prank(keeper); // the keeper can't upgrade either: owner only
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
		factory.upgradeTo('FrostyClmStrategy-v1', v2);

		factory.upgradeTo('FrostyClmStrategy-v1', v2);
		assertEq(proxy.version(), 2);
	}

	function test_rebalancersAndPause_roles() public {
		address rebalancer = makeAddr('rebalancer');
		vm.prank(stranger);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
		factory.addRebalancer(rebalancer);
		factory.addRebalancer(rebalancer);
		assertTrue(factory.rebalancers(rebalancer));
		vm.prank(keeper);
		factory.removeRebalancer(rebalancer);
		assertFalse(factory.rebalancers(rebalancer));

		vm.prank(keeper);
		factory.pauseAllStrats();
		assertTrue(factory.globalPause());
		vm.prank(keeper);
		vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
		factory.unpauseAllStrats();
		factory.unpauseAllStrats();
		assertFalse(factory.globalPause());
	}
}

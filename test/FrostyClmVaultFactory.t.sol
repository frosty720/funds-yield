// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Test} from 'forge-std/Test.sol';
import {FrostyClmVault} from '../contracts/vault/FrostyClmVault.sol';
import {FrostyClmVaultFactory} from '../contracts/vault/FrostyClmVaultFactory.sol';

contract FrostyClmVaultFactoryTest is Test {
	event ProxyCreated(address proxy);

	FrostyClmVaultFactory internal factory;

	function setUp() public {
		factory = new FrostyClmVaultFactory(address(0));
	}

	function test_cloneVault_isAMinimalProxyOfTheInstance() public {
		FrostyClmVault vault = factory.cloneVault();
		bytes memory expected = abi.encodePacked(
			hex'363d3d373d3d3d363d73', address(factory.instance()), hex'5af43d82803e903d91602b57fd5bf3'
		);
		assertEq(address(vault).code, expected);
	}

	function test_cloneVault_emitsProxyCreated() public {
		vm.expectEmit(false, false, false, false, address(factory));
		emit ProxyCreated(address(0));
		factory.cloneVault();
	}

	function test_clone_initializesOnce() public {
		FrostyClmVault vault = factory.cloneVault();
		vault.initialize(address(0xBEEF), 'FrostyFi CLM test', 'fcTEST');
		assertEq(address(vault.strategy()), address(0xBEEF));
		assertEq(vault.owner(), address(this));
		vm.expectRevert('Initializable: contract is already initialized');
		vault.initialize(address(0xBEEF), 'x', 'x');
	}

	function test_instance_cannotBeInitialized() public {
		FrostyClmVault instance = factory.instance();
		vm.expectRevert('Initializable: contract is already initialized');
		instance.initialize(address(0xBEEF), 'x', 'x');
	}
}

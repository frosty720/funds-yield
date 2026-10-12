// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Test} from 'forge-std/Test.sol';
import {Bytecode} from './utils/Bytecode.sol';

/// @notice The copied Beefy sources compile to the runtime bytecode of Beefy's verified Base contracts (metadata
///         multihashes masked). Hashes computed 2026-10-11 from `cast code` (Base, block ≈ 52489276):
///         strategy implementation 0xFc90cf1235a4fbE38b1A14d989627f0A2deCB433, vault implementation
///         0x6f9989a4d84edb5068bd37ee8c55c6e97d00c723, StrategyFactory 0x9476284d81121613DA5DF5C72f50853a455448F1.
contract BeefyBytecodeTest is Test {
	bytes32 private constant LIVE_VAULT = 0xc4338fbfdcedfbd58d36f2d1bf6fbc08e685c1e8f72c2ce58cf939ec68440566;

	function _masked(string memory artifact) private view returns (bytes32) {
		return keccak256(Bytecode.maskMetadata(vm.getDeployedCode(artifact)));
	}

	function test_vaultIsBeefyVault() public view {
		assertEq(_masked('FrostyClmVault.sol:FrostyClmVault'), LIVE_VAULT);
	}

	function test_maskMetadata_zeroesOnlyTheHash() public pure {
		bytes memory code = hex'6080a2646970667358221220ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff64736f6c634300081700336080';
		bytes memory masked = Bytecode.maskMetadata(code);
		assertEq(masked, bytes.concat(hex'6080a264697066735822', new bytes(34), hex'64736f6c634300081700336080'));
	}
}

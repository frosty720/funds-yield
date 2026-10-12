// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

/// @notice solc appends a CBOR blob to every contract, including each child contract embedded for `new`:
///         `a2 64 'ipfs' 58 22`, a 34-byte multihash, `64 'solc' 43`, the version and a length. The multihash covers
///         source paths and comments, so it changes with any rename; nothing else in the bytecode does.
library Bytecode {
	bytes8 private constant IPFS_PREFIX = 0xa264697066735822;
	uint256 private constant HASH_LENGTH = 34;

	/// @dev Zeroes every metadata multihash in `code`, in place.
	function maskMetadata(bytes memory code) internal pure returns (bytes memory) {
		uint256 i;
		while (i + 8 + HASH_LENGTH <= code.length) {
			if (_prefixAt(code, i)) {
				for (uint256 j = i + 8; j < i + 8 + HASH_LENGTH; ++j) code[j] = 0;
				i += 8 + HASH_LENGTH;
			} else {
				++i;
			}
		}
		return code;
	}

	function _prefixAt(bytes memory code, uint256 i) private pure returns (bool) {
		bytes32 word;
		assembly {
			word := mload(add(add(code, 32), i))
		}
		return bytes8(word) == IPFS_PREFIX;
	}
}

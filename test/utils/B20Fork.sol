// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Test} from 'forge-std/Test.sol';

/// @notice A plain ERC-20 put at a B20 token's address on a fork. Coinbase's stock tokens are B20: Base-node precompiles
///         whose account code is the one byte 0xef, which Foundry's EVM can't run. The stand-in starts with the real
///         decimals and the real balances of the holders a test names, read from Base at the fork block (B20Fork), so a
///         pool keeps its real reserves and everything around the token (the pool, its swap hook, the strategy, the
///         vault) runs as live code. The token's own transfer rules (Base's Policy Registry) it can't stand in for: a
///         test reads those from Base itself (B20Fork._b20Allows).
contract B20StandIn {
	uint8 public decimals;
	uint256 public totalSupply;
	mapping(address => uint256) public balanceOf;
	mapping(address => mapping(address => uint256)) public allowance;

	event Transfer(address indexed from, address indexed to, uint256 value);
	event Approval(address indexed owner, address indexed spender, uint256 value);

	function setDecimals(uint8 decimals_) external {
		decimals = decimals_;
	}

	function mint(address to, uint256 amount) external {
		balanceOf[to] += amount;
		totalSupply += amount;
		emit Transfer(address(0), to, amount);
	}

	function approve(address spender, uint256 amount) external returns (bool) {
		allowance[msg.sender][spender] = amount;
		emit Approval(msg.sender, spender, amount);
		return true;
	}

	function transfer(address to, uint256 amount) external returns (bool) {
		_move(msg.sender, to, amount);
		return true;
	}

	function transferFrom(address from, address to, uint256 amount) external returns (bool) {
		uint256 allowed = allowance[from][msg.sender];
		if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
		_move(from, to, amount);
		return true;
	}

	function _move(address from, address to, uint256 amount) private {
		balanceOf[from] -= amount;
		balanceOf[to] += amount;
		emit Transfer(from, to, amount);
	}
}

/// @notice Fork helpers for B20 tokens: the stand-in, and the live token's transfer rules read from Base.
abstract contract B20Fork is Test {
	/// @dev Base's Policy Registry precompile; each B20 asks it `isAuthorized(policyId, account)` for three scopes
	///      (funds-keeper src/b20/policy-watch.ts: SENDER checks `from`, RECEIVER `to`, EXECUTOR `msg.sender`).
	address internal constant POLICY_REGISTRY = 0x8453000000000000000000000000000000000002;

	/// @dev The block every `vm.rpc` read is made at: the fork block, whatever the test has rolled to since.
	uint256 internal b20Block;

	/// @dev Puts the stand-in at `token` with its real decimals and each holder's real balance at the fork block.
	function _standIn(address token, address[] memory holders) internal {
		require(keccak256(token.code) == keccak256(hex'ef'), 'not a B20 on this fork');
		if (b20Block == 0) b20Block = block.number;
		uint8 decimals = abi.decode(_chainCall(token, abi.encodeWithSignature('decimals()')), (uint8));
		uint256[] memory balances = new uint256[](holders.length);
		for (uint256 i; i < holders.length; ++i) {
			balances[i] = abi.decode(_chainCall(token, abi.encodeWithSignature('balanceOf(address)', holders[i])), (uint256));
		}
		vm.etch(token, type(B20StandIn).runtimeCode);
		B20StandIn(token).setDecimals(decimals);
		for (uint256 i; i < holders.length; ++i) {
			B20StandIn(token).mint(holders[i], balances[i]);
		}
	}

	/// @dev Whether the live token, at the fork block, lets `account` send, receive and move it (all three scopes), with
	///      no feature paused.
	function _b20Allows(address token, address account) internal returns (bool) {
		bytes memory paused = _chainCall(token, abi.encodeWithSignature('pausedFeatures()'));
		if (abi.decode(paused, (uint8[])).length != 0) return false;
		string[3] memory scopes = ['TRANSFER_SENDER_POLICY', 'TRANSFER_RECEIVER_POLICY', 'TRANSFER_EXECUTOR_POLICY'];
		for (uint256 i; i < 3; ++i) {
			bytes memory id = _chainCall(token, abi.encodeWithSignature('policyId(bytes32)', keccak256(bytes(scopes[i]))));
			bytes memory ok = _chainCall(
				POLICY_REGISTRY, abi.encodeWithSignature('isAuthorized(uint64,address)', abi.decode(id, (uint64)), account)
			);
			if (!abi.decode(ok, (bool))) return false;
		}
		return true;
	}

	/// @dev eth_call against the real chain at the fork block (Base's node runs the precompiles).
	function _chainCall(address to, bytes memory data) internal returns (bytes memory) {
		uint256 at = b20Block == 0 ? block.number : b20Block;
		string memory params =
			string.concat('[{"to":"', vm.toString(to), '","data":"', vm.toString(data), '"},"', _hexQuantity(at), '"]');
		return vm.rpc('eth_call', params);
	}

	function _hexQuantity(uint256 n) internal pure returns (string memory) {
		if (n == 0) return '0x0';
		bytes16 digits = '0123456789abcdef';
		uint256 len;
		for (uint256 t = n; t != 0; t >>= 4) {
			++len;
		}
		bytes memory out = new bytes(len + 2);
		out[0] = '0';
		out[1] = 'x';
		for (uint256 i = len + 1; i > 1; --i) {
			out[i] = digits[n & 0xf];
			n >>= 4;
		}
		return string(out);
	}
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Test} from 'forge-std/Test.sol';
import {IERC20} from '@openzeppelin-4/contracts/token/ERC20/IERC20.sol';
import {FrostyClmStrategyV2} from '../../contracts/strategies/aero/FrostyClmStrategyV2.sol';
import {FrostyClmStrategyFactory} from '../../contracts/strategies/FrostyClmStrategyFactory.sol';
import {FrostyClmVault} from '../../contracts/vault/FrostyClmVault.sol';

/// @notice The beacon upgrade for the fee fix (red-team YIELD-02, 2026-10-27), on the live v2 factory and the live USDC-WETH
///         vault: every strategy keeps its address and storage, and takes a deposit and pays it back on the new code.
///         Run: BASE_MAINNET_RPC=<archive url> forge test --match-path test/fork/UpgradeClmStrategyV2Fork.t.sol -vv
contract UpgradeClmStrategyV2ForkTest is Test {
	uint256 internal constant FORK_BLOCK = 53_380_000;
	address internal constant OWNER = 0xaE51f2EfE70e57b994BE8F7f97C4dC824c51802a;
	address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
	address internal constant WETH = 0x4200000000000000000000000000000000000006;
	address internal constant POOL = 0x4A7af46bC8aBc00048c6c7920a1488DAF568366c;
	FrostyClmVault internal constant VAULT = FrostyClmVault(0x7be92D15f7cC0E458fa06243072197440E47b234);
	FrostyClmStrategyV2 internal constant STRATEGY = FrostyClmStrategyV2(payable(0x1Bda2790A85164539521656d24dF36aA3BEdcd45));

	bool internal forked;
	FrostyClmStrategyFactory internal factory;
	string internal name;
	address internal alice = makeAddr('alice');

	function setUp() public {
		string memory rpc = vm.envOr('BASE_MAINNET_RPC', string(''));
		if (bytes(rpc).length == 0) return;
		vm.createSelectFork(rpc, FORK_BLOCK);
		vm.setEvmVersion('cancun'); // Aero's pools use Cancun opcodes (as DeployClmV2Fork)
		forked = true;
		string memory book = vm.readFile('deployments/base-mainnet-clm-v2.json');
		factory = FrostyClmStrategyFactory(vm.parseJsonAddress(book, '.strategyFactory'));
		name = vm.parseJsonString(book, '.strategyName');
		address implementation = address(new FrostyClmStrategyV2());
		vm.prank(OWNER);
		factory.upgradeTo(name, implementation);
	}

	function test_fork_theUpgradeKeepsEveryStrategysStorage() public {
		vm.skip(!forked);
		assertEq(STRATEGY.vault(), address(VAULT));
		assertEq(STRATEGY.pool(), POOL);
		assertEq(STRATEGY.lpToken0(), WETH);
		assertEq(STRATEGY.lpToken1(), USDC);
		assertEq(STRATEGY.fees0() + STRATEGY.fees1(), 0);
		assertEq(STRATEGY.totalLocked0() + STRATEGY.totalLocked1(), 0, 'nothing locked in the live strategies');
		(uint256 locked0, uint256 locked1) = STRATEGY.lockedProfit();
		assertEq(locked0 + locked1, 0);
	}

	function test_fork_theLiveVaultTakesADepositAndPaysItBack() public {
		vm.skip(!forked);
		deal(WETH, alice, 1 ether);
		deal(USDC, alice, 3_000e6);
		vm.startPrank(alice);
		IERC20(WETH).approve(address(VAULT), 1 ether);
		IERC20(USDC).approve(address(VAULT), 3_000e6);
		VAULT.deposit(1 ether, 3_000e6, 0);
		uint256 shares = VAULT.balanceOf(alice);
		assertGt(shares, 0);
		vm.stopPrank();
		vm.roll(block.number + 1);
		skip(121);
		vm.prank(alice);
		VAULT.withdrawAll(0, 0);
		assertEq(VAULT.balanceOf(alice), 0);
		assertGt(IERC20(WETH).balanceOf(alice) + IERC20(USDC).balanceOf(alice), 0, 'paid back');
	}
}

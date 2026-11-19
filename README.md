# FrostyFi funds-yield

Managed-range liquidity vaults for FrostyFi on Base.

A vault takes the two tokens of an Aero concentrated-liquidity pool, keeps them in a price range around the current price, and collects the trading fees the position earns. Fees stay in the vault, so each share is worth more of both tokens over time. FrostyFi funds deposit into these vaults through [funds-core](https://github.com/FrostyLabsAi/funds-core); anyone can also deposit directly.

The contracts are a fork of Beefy's Cowcentrated Liquidity Manager. They are live on Base mainnet in public beta. The terminal is at [frostyfi.fund](https://frostyfi.fund).

## Contents

- [How a vault works](#how-a-vault-works)
- [Contracts](#contracts)
- [Changes from Beefy](#changes-from-beefy)
- [Limits](#limits)
- [Roles](#roles)
- [Build and test](#build-and-test)
- [Deployments](#deployments)
- [Deploying](#deploying)
- [Security](#security)
- [License](#license)

## How a vault works

Each vault is a pair of contracts: a `FrostyClmVault`, which holds the shares, and a strategy, which holds the liquidity.

1. **Deposit.** A depositor calls `deposit(amount0, amount1, minShares)` on the vault and receives shares (an ERC-20). The vault takes the two tokens in the proportion it needs; `previewDeposit` returns that proportion and the shares to expect. The first deposit into a vault locks 1,000 share units for good, which protects the share price against manipulation of an empty vault.
2. **Positions.** The strategy holds two positions in the pool. The main position is centred on the current price and reaches a set number of tick spacings on each side. The second position holds whatever single token is left over, as a one-sided range next to the current price.
3. **Fees.** Every deposit, withdrawal, rebalance and harvest collects the fees both positions have earned, in both tokens. A performance fee goes to FrostyFi's treasury in the same tokens. The rest joins the vault's balances at once, so it is in the share price from that moment.
4. **Rebalance.** When the price moves, an approved rebalancer calls `moveTicks`, which removes the liquidity and places both positions around the new price.
5. **Withdraw.** A holder calls `withdraw(shares, minAmount0, minAmount1)` and receives their share of both tokens. A withdrawal is not stopped by a pause.

**The calm check.** Deposits, rebalances and harvests run only while the pool's price is calm: the current price and its 3-second average must both be within a set distance of the pool's time-weighted average price. This keeps a vault from adding liquidity at a price someone has just pushed. A withdrawal is paid whether or not the price is calm, except in the same block as a deposit; if the price isn't calm, the remaining liquidity waits in the strategy and is added back at the next calm action.

## Contracts

| Contract | Role |
|---|---|
| `vault/FrostyClmVault` | The share token and the entry point: deposit, withdraw and their previews. |
| `vault/FrostyClmVaultFactory` | Deploys vaults as minimal clones. |
| `strategies/aero/FrostyClmStrategyV2` | The current strategy, for Aero's Slipstream pools. Positions are not staked and earn the pool's trading fees. |
| `strategies/velodrome/FrostyClmStrategy` | The first strategy. It staked positions in a gauge and compounded the AERO rewards. The live vaults use v2. |
| `strategies/FrostyClmStrategyFactory` | Deploys strategies behind a beacon and holds the settings they share: the treasury, the performance fee, the keeper and the approved rebalancers. |
| `strategies/StratFeeManagerInitializable` | The strategies' shared base: ownership, pause, and the fee and keeper reads from the factory. |
| `deploy/ClmPoolDeployer`, `ClmPoolDeployerV2` | Deploy and initialize one pool's strategy and vault in a single transaction, so nobody else can initialize them first. |
| `utils/` | Tick, liquidity and path math. |

Inside a FrostyFi fund, vault shares are valued by funds-core's `ClmVaultPriceFeed` at oracle prices, never at the pool's current price.

## Changes from Beefy

- The vault is Beefy's `BeefyVaultConcLiq`, renamed, with no change in logic. A test checks that it compiles to the same bytecode as Beefy's deployed vault on Base.
- Beefy's fee configuration is replaced by one performance fee, paid to FrostyFi's treasury and bounded in bytecode.
- The v2 strategy never stakes its positions. It earns the pool's trading fees instead of gauge rewards, so it sells nothing.
- Collected fees are in the share price at once. Beefy releases them over a day after each harvest.
- Harvests can be called only by the keeper or the owner.
- After a withdrawal, liquidity is added back only at a calm price.

## Limits

| Limit | Value | Where |
|---|---|---|
| Performance fee | 5% to 30% of collected fees; set to 9.5% | `FrostyClmStrategyFactory.MIN_PERF_FEE_BPS`, `MAX_PERF_FEE_BPS` |
| Time-weighted average window | at least 60 seconds | `setTwapInterval` |
| Calm distance | under 40 tick spacings | `setDeviation` |
| Shares locked at the first deposit | 1,000 units | `FrostyClmVault.MINIMUM_SHARES` |

## Roles

| Role | Can |
|---|---|
| Factory owner | Upgrade a strategy type's implementation, which upgrades every strategy of that type in place. Set the treasury, the performance fee within its bounds, and the keeper. Approve rebalancers. Lift a pause on all strategies. |
| Keeper | Harvest. Pause a strategy and pull its liquidity out of the pool (`panic`), and resume it. Pause all strategies. Add a strategy type. Remove a rebalancer. |
| Rebalancer | Move a strategy's positions to the current price, at a calm price only. |
| Strategy owner | Set the position width, the average window and the calm distance. Retire a vault once only its locked shares remain. |
| Vault owner | Recover tokens sent to the vault contract by mistake. The vault holds no deposits; they sit in the strategy. |
| Anyone | Deposit and withdraw. |

Strategies are upgradeable: they are beacon proxies, and the factory owner controls the beacon. Vaults are not upgradeable.

## Build and test

Requires [Foundry](https://getfoundry.sh).

```bash
git clone --recurse-submodules https://github.com/FrostyLabsAi/funds-yield
cd funds-yield
forge build
forge test
```

The fork suites in `test/fork` run against Base mainnet state and are skipped when no RPC is set:

```bash
BASE_MAINNET_RPC=<archive RPC URL> forge test
```

`BASE_FORK_BLOCK` pins the fork to a block.

The compiler settings are Beefy's and must not change, or the bytecode test fails: Solidity 0.8.23, EVM version Paris, 200 optimizer runs, OpenZeppelin Contracts 5.0.2 and OpenZeppelin Contracts Upgradeable 4.9.6.

Coverage needs `--ir-minimum`, because Beefy's code doesn't compile without the optimizer, and must skip the bytecode test, because coverage compiles different bytecode. Its line attribution is approximate.

```bash
BASE_MAINNET_RPC=<archive RPC URL> forge coverage --ir-minimum --no-match-contract BeefyBytecodeTest --report summary
```

## Deployments

Base mainnet, chain ID 8453.

| Contract | Address |
|---|---|
| FrostyClmStrategyFactory | `0x99c49323e589136BD4F9937b6ae226fD25A267aa` |
| FrostyClmVaultFactory | `0x13a4FD7dD96D01BA22bddF8e3D8B56b81c073C74` |
| FrostyClmStrategyV2 implementation | `0x63679fb945f223a9E1389fA50Ef511c391D3CB42` |
| ClmPoolDeployerV2 | `0x8a494d4f32A228c3839CF12E640707296B8e63E7` |

The 24 v2 vaults, with each vault's strategy and pool, are in [`deployments/base-mainnet-clm-v2.json`](deployments/base-mainnet-clm-v2.json). They cover USDC paired with 18 tokenized stocks, WETH and cbBTC, and WETH paired with EURC, MORPHO, USDT and VVV. The v1 vaults are in [`deployments/base-mainnet-clm.json`](deployments/base-mainnet-clm.json).

## Deploying

A deployment has three steps:

1. `script/DeployClmV2.s.sol` deploys the strategy implementation and the pool deployer, and adds the strategy type to the factory.
2. One `deployPool` call per pool, with the settings in `script/config/base-mainnet-pools-v2.json`. These are sent with `cast send`, not from a Forge script: Forge simulates a script locally first, and Coinbase's tokenized stocks run only on Base's own node.
3. `script/DeployClmV2.s.sol --sig 'writeDeployments(address)'` reads the result from the chain and writes the deployment record.

`script/DeployClm.s.sol` is the same for v1, including the two factories. `script/UpgradeClmStrategyV2.s.sol` points the v2 beacon at a new implementation.

## Security

The contracts are tested with unit tests and with fork tests against Base mainnet state.

FrostyFi's changes have not been audited by a third party. This is beta software: use it at your own risk.

To report a vulnerability, use GitHub's private reporting: open the repository's **Security** tab and click **Report a vulnerability**, or go to [the report form](https://github.com/FrostyLabsAi/funds-yield/security/advisories/new). Please don't open a public issue.

## License

MIT; see [`LICENSE`](LICENSE). The files derived from Beefy's Cowcentrated Liquidity Manager are listed in [`NOTICE`](NOTICE) with the license they were published under. `contracts/utils/Path.sol` is GPL-2.0-or-later and `contracts/utils/BytesLib.sol` is released under the Unlicense.

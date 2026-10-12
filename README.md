# funds-yield

FrostyFi yield vaults: Beefy's concentrated liquidity manager (CLM), forked, renamed and changed to pay a FrostyFi
performance fee and to compound AERO. See `NOTICE`.

```bash
forge build
forge test                                                    # fork tests are skipped without an RPC
BASE_MAINNET_RPC=<archive rpc> forge test                     # everything (optional BASE_FORK_BLOCK)
```

Compiler setup is Beefy's and must not change: solc 0.8.23, EVM paris, 200 runs, OZ 5.0.2 + OZ-upgradeable 4.9.6.

## Deploy (founder)
`KEEPER_ADDRESS=<keeper Engine wallet> forge script script/DeployClm.s.sol --rpc-url base --account frosty-main --sender <deployer> --broadcast --slow --verify`
writes `deployments/base-mainnet-clm.json`. Then register each vault in FrostyFi's ValueInterpreter (funds-core, plan 2).

## Coverage
`forge coverage` needs `--ir-minimum` (Beefy's code is stack-too-deep without the optimizer) and must skip the
bytecode-identity test (coverage compiles different bytecode):
`BASE_MAINNET_RPC=<archive rpc> forge coverage --ir-minimum --no-match-contract BeefyBytecodeTest --report summary`.
Under via-IR its line attribution is approximate.

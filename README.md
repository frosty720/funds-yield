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
Three steps. forge simulates every script locally, and stock tokens (B20) only run on Base's own node, so the stock
pools are deployed with `cast` (same rule as MAINNET_RUNBOOK_FUNDS.md for listing stocks).

1. Factories, strategy implementation and `ClmPoolDeployer` (prints the deployer's address):
   `KEEPER_ADDRESS=<keeper Engine wallet> forge script script/DeployClm.s.sol --rpc-url base --account frosty-main --sender <deployer> --broadcast --slow --verify`
2. One transaction per stock pool (strategy + vault created, initialized and handed to the deployer key at once):
   ```bash
   D=<ClmPoolDeployer address>
   jq -c '.[]' script/config/base-mainnet-pools.json | while read -r p; do
     cast send $D 'deployPool((address,int56,address,int24,address,string,uint32))' \
       "($(echo "$p" | jq -r '[.gauge,.maxTickDeviation,.pool,.positionWidth,.stockToken,.symbol,.twapInterval]|map(tostring)|join(",")'))" \
       --rpc-url base --account frosty-main
   done
   ```
3. Read-only: `forge script script/DeployClm.s.sol --sig 'writeDeployments(address)' $D --rpc-url base` writes
   `deployments/base-mainnet-clm.json` from the chain.

Then register each vault in FrostyFi's ValueInterpreter (funds-core, plan 2).

## Coverage
`forge coverage` needs `--ir-minimum` (Beefy's code is stack-too-deep without the optimizer) and must skip the
bytecode-identity test (coverage compiles different bytecode):
`BASE_MAINNET_RPC=<archive rpc> forge coverage --ir-minimum --no-match-contract BeefyBytecodeTest --report summary`.
Under via-IR its line attribution is approximate.

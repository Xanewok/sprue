# token-vault

One chain, two units. `token` deploys and checks a `Token`; `vault` needs the checked token, deploys a
`Vault` for it, and funds it once a date has passed. It also shows `recover`: rebuilding a lost journal
from forge's broadcast records.

```
sprue.json                              paths and chain policy (31337 is local)
deployments/local/network.json          the network's one chain, l2
deployments/local/vault.input.json      openAt: the funding date
script/deploy/DeployGraph.s.sol         lists the units
script/deploy/units/token/              Token, and its steps: deploy, check, recover
script/deploy/units/vault/              Vault, and its steps: deploy, fund (dated), check
script/deploy/graph.generated.json      saved `sprue json`; regenerate it after changing a step
```

## Run it on Anvil

Copy this directory out of the sprue checkout, then:

```sh
git init && forge install foundry-rs/forge-std Xanewok/sprue@v0.1.3
anvil &                                  # chain 31337 on :8545
G="node lib/sprue/bin/sprue.mjs"
$G plan local vault.check                # the next commands; sends nothing
$G run local vault.check                 # deploys, checks, funds, checks
rm deployments/local/token.json          # lose a journal
$G run local vault.check                 # refused: prints the `recover` command
```

1. `plan` prints the commands that reach `vault.check`. Only the token's appear: `vault.deploy` needs the
   checked token, so it is planned once the token is done.
2. `run` sends what `plan` prints and plans again until the target is done. `vault.fund` waits for
   `openAt` (the year 2100 here); on Anvil `run` moves the chain's clock to it.
3. With the journal gone, `run` refuses to deploy a second token: the broadcast record holds a `Token`
   CREATE the journal lacks. Run the `recover` command it prints (this unit's script with
   `--sig 'recover(string)'`), then `run` again: it reaches done and sends nothing.

## For a real network

- Add `deployments/<network>/network.json` with the chain's id and an `rpc` alias from `foundry.toml`'s
  `[rpc_endpoints]`, and list the id in `sprue.json`'s `chains.test` if it is a test chain.
- Set `openAt` in `vault.input.json` to the real date. Off Anvil, `run` exits 4 until the chain's clock
  reaches it, or waits with `--wait`.
- A non-local `run` is attended ([Your own project](https://github.com/Xanewok/sprue/blob/main/GUIDE.md#your-own-project), step 7). Commit
  `deployments/<network>` and `broadcast/`: `recover` reads them.
- Replace `Token` and `Vault`, and their constructor arguments, with your own contracts.

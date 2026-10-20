# sprue

sprue runs a multi-step Foundry deployment from a graph of steps declared in Solidity. Each step is one
`forge script` command. `sprue plan` prints the commands a target still needs and sends nothing.
`sprue run` sends them, plans again, and stops when the target is done. On a network with a chain that
is not local, `run` shows each step's dry run and sends it only after you type `yes`.

Plain `forge script` with `--resume` finishes one interrupted broadcast of one script. It has no graph
and no journal, and a rerun resends every CREATE. sprue orders the steps as a graph and keeps a journal
per unit, so a rerun finishes an interrupted deployment and a rerun of a finished one sends nothing. A
step can wait for a date or for a fact on chain, one network can span several chains, and
`sprue rehearse` runs a target on Anvil forks first.

0.x: the API may change in any 0.x release. [DESIGN.md](DESIGN.md) holds the assumptions, invariants,
decisions and [prior art](DESIGN.md#prior-art), [SECURITY.md](SECURITY.md) what the guards check,
[ROADMAP.md](ROADMAP.md) the plans, and [CHANGELOG.md](CHANGELOG.md) what each release changed.

## Quick start

sprue needs Node 18 or later, `git`, `cast`, `forge` 1.8 or later (CI pins v1.8.5), and `anvil` for
`rehearse`; Windows without WSL is not yet tested. Run [`examples/token-vault`](examples/token-vault), a
complete project that CI runs, from a clone:

```sh
cp -R examples/token-vault ../my-deploy && cd ../my-deploy
git init && forge install foundry-rs/forge-std Xanewok/sprue@v0.1.3
anvil &                                   # chain 31337 on :8545
export DEPLOYER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
node lib/sprue/bin/sprue.mjs plan local vault.check   # the next commands; sends nothing
node lib/sprue/bin/sprue.mjs run local vault.check    # deploys, checks, funds, checks
```

The first `plan` prints:

```
# chain l2 31337 local
forge script script/deploy/units/token/DeployToken.s.sol:DeployToken --sig 'deploy(string)' local --rpc-url local --sender $DEPLOYER
forge script script/deploy/units/token/DeployToken.s.sol:DeployToken --sig 'check(string)' local --rpc-url local --sender $DEPLOYER
# then plan again vault.deploy
```

The vault needs the token's address, so the plan stops until those two commands land. `run` sends them
and plans again until all five steps print `# done`, and a second `run` sends nothing. The example's
[README](examples/token-vault/README.md) explains each step, then loses a journal and rebuilds it.

## Install

Install with `forge install foundry-rs/forge-std Xanewok/sprue@v0.1.3`. The remapping is
`sprue/=lib/sprue/src/` and the runner is `node lib/sprue/bin/sprue.mjs`. With npm
(`npm i -D @xanewok/sprue`) they are `sprue/=node_modules/@xanewok/sprue/src/` and `npx sprue`. Below,
`sprue` means either.

## Concepts

- **Unit**: a Forge script `Deploy<Name>.s.sol` that inherits `Unit` and holds the steps for a few
  related contracts. The contracts it deploys are its **roles**, named by strings such as `"token"`.
- **Journal**: `deployments/<network>/<unit>.json`, committed: each role's address, deployer, nonce
  and code hash, and the path of its build metadata file beside it.
- **Step**: an external function of a unit that takes the network name (and an index, for a step per
  index), with an id such as `token.deploy`. Each step runs as its own `forge script` command.
- **Certificate**: the journal's `checked` object, which the unit's `check` step writes. It marks done
  the unit's steps that `check` follows and that have no `Due` view; other units read addresses from it.
- **Graph**: a script that inherits `FileGraph`, registers the units, and orders their steps by
  `.needs(...)`.

The example's vault unit declares its steps like this:

```solidity
function steps() external view returns (Step[] memory s) {
    s = new Step[](3);
    s[0] = _step("vault.deploy", this.deploy, this.deployDue).needs("token.check");
    s[1] = _step("vault.fund", this.fund, this.fundDue).needs("vault.deploy").notBefore("vault.openAt");
    s[2] = _step("vault.check", this.check).needs("vault.fund");
}
```

## Your own project

1. Copy `sprue.json` and `.gitignore` from the example, and merge its `foundry.toml` into yours: the
   `fs_permissions` and the `[rpc_endpoints]` aliases (its `src = "script"` suits only the example).
   `sprue` runs from any directory below `sprue.json`, and refuses unless git ignores
   `<paths.rehearsal>/` and `<paths.rehearsal>-x/`.
2. Add `deployments/<network>/network.json`, which gives each chain its id and an `rpc` alias from
   `foundry.toml`'s `[rpc_endpoints]`: `{"chains":{"l2":{"id":31337,"rpc":"local"}}}`.
3. Write one unit per directory under `script/deploy/units/<unit>/`, with the example's
   [`DeployToken.s.sol`](examples/token-vault/script/deploy/units/token/DeployToken.s.sol) as a
   template. Every step needs a done rule: a `<fn>Due` view, as in `_step(id, this.fn, this.fnDue)`, or
   a `check` step of the same unit that reaches it through `.needs(...)`.
4. Register the units in a graph script whose contract is named like its file: its constructor calls
   `_add(address(new DeployToken()), "<path>:DeployToken")` for each unit, then `_validateGraph()`, as in
   the example's [`DeployGraph.s.sol`](examples/token-vault/script/deploy/DeployGraph.s.sol).

5. Save the graph beside its script: `sprue json > script/deploy/graph.generated.json`. Save it again
   whenever you add, rename or rewire a step, because `plan` and `run` refuse a target this file lacks.
   `sprue list` prints the targets, the nodes nothing depends on, and `sprue mermaid [target]` draws
   the saved graph.
6. Plan with `sprue plan <network> <target>`, which reads the default chain's `rpc` and sends nothing.
7. Run with `sprue run <network> <target>`. `DEPLOYER` sends the steps that name no sender. On a network
   whose chains are all in `chains.local`, the run is unattended and needs `DEPLOYER` set; it sends
   unlocked on Anvil and signs with `KEY` (Anvil's dev key if unset) on another node. On any other
   network a person runs it at a terminal, with no `CI` variable, from a clean git checkout, signing
   with exactly one of `--account <name>`, `--ledger` or `--trezor`. There `DEPLOYER` defaults to the
   signer's address, a step that another account sends is refused, and each step is sent only after
   `yes` is typed at its dry run.
8. Once the run stops, commit each step's journal, metadata and `broadcast/` records; each step prints
   its `git add`. An attended run refuses a commit made while it waits for `yes`. `recover` reads the
   records, so never git-ignore a public chain's.
9. When a run on a live chain ends done or waiting, it offers an annotated tag `deploy/<network>/<unit>`
   for each unit certified on a live chain, at the commit its journal records, and to push it. Tags never
   move and are never overwritten; a journal that records a dirty tree or several commits gets no tag. A
   failed push prints its retry command and keeps the run's status.

Two flags are a person's decision, never a way past a refusal. `--allow-dirty` starts on a dirty tree
and is refused when any chain is live. `--unsafe-unexpected-deployer` lets a deploy step send with a key
other than the pinned `deployer`. `sprue --help` lists the flags and the exit codes.

A unit's directory, its `_unit()` and the prefix of its step ids are one name, and a contract `<Name>`
that it deploys is declared in the project's only file named `<Name>.sol`. The typed forms
`_step(id, this.fn)`, `_step(id, this.fn, this.fnDue)` and `_step(id, name, this.fn, this.fnDue, i)`
let the compiler check each function and its `Due` view. The selector forms, such as
`_step(id, X.fn.selector)`, remain for other signatures, and [`src/graph/Step.sol`](src/graph/Step.sol)
holds the other builders. A unit pins every contract it reads but does not deploy, by code hash or by
behaviour, in its own checks.

## Rehearse

`sprue rehearse <network> <target>` runs what `run` would send on Anvil forks that it starts, in
`<paths.rehearsal>-<network>`, a fresh copy of the files directly in `deployments/<network>/` that stays
as the report. Each chain forks from its `rpc` alias at `--block [<chain>=]<n>`, else at the latest
block. The copied journals keep `checked`, so a step that the certificate marks done stays done, and
the copy's `network.json` names each fork's loopback URL as its chain's `rpc`. A fork that lacks the
code a copied certificate names, as at a `--block` before the deployment, is refused.

Senders are impersonated:
`DEPLOYER` (else the pinned `deployer`) and each `.by(...)`. No key signs, so a signer flag is refused,
as are a keystore that `.env` names and the `.env` and `foundry.toml` settings that `run` refuses.
`rehearse` runs unattended and on a dirty tree, which the journals record, and moves each fork's clock
to the next date. A fork of a chain that [`bin/chains.json`](bin/chains.json) lists takes that chain's
deployed-code limit and twice it for init code; each entry names its evidence. The forks stop at the end
and on Ctrl-C; `--keep` leaves them running, named in the copy's `network.json`, until the next
`rehearse` of the network or `sprue rehearse --stop <network>`. A kept fork that does not answer counts
as stopped.

## Configuration

`sprue.json` has exactly the keys `paths` and `chains`:

- `paths.graph`, `paths.units`, `paths.deployments`: the graph script, the directory of unit directories
  (one `Deploy*.s.sol` each), and the directory of network directories. Plan lines carry the paths
  unquoted, so each is a nonempty string using only `A-Z a-z 0-9 _ . / -`.
- `paths.rehearsal`: `<paths.deployments>/<name>`, with a lower-case `<name>`. A network `<name>` or
  `<name>-<suffix>` is a rehearsal network, which git must ignore, and whose commands keep forge's
  records and resume data in its own directory. Because its journals and records are git-ignored, a
  `sprue run` on one needs Anvil or a `chains.local` id on every chain.
- `chains.default` (optional): the chain of a step without `.on(...)`, else a network's only chain.
- `chains.local` and `chains.test`: the ids of development and test chains. Any other id is live. A
  `.forTests()` step is a target only on these chains, and the nonce fence guards only live ones.
- `chains.unrecordedDeploys`: `{"<chain id>": "<reason>"}` turns off the nonce fence on that live chain,
  for a deploy key that already deployed outside the graph. Leave it `{}` otherwise.

In `network.json`, each chain names an `rpc` alias from `foundry.toml`'s `[rpc_endpoints]`, which forge
and cast resolve with `.env`. A committed `network.json` never holds a URL, which may carry a key. A
top-level `"deployer": "0x..."` pins the deploy key.

Before each send, `run` refuses what would make forge run a line otherwise than printed: a
`foundry.toml` setting or inherited variable that moves forge's records; `FOUNDRY_ETH_RPC_URL`,
`FOUNDRY_SENDER` or `FOUNDRY_RPC_ENDPOINTS` (or a `DAPP_` or `DAPP_TEST_` form) in the environment or
`.env`; and an `eth_rpc_url` or a non-default `sender` in `foundry.toml`.

## When a run refuses

Each refusal names its remedy. These need a person:

- A lost journal makes its deploy step refuse. If the journal was ever committed, restore it from git.
  Otherwise run the `recover` command the refusal prints, if any, with the build and inputs that made
  the deployment; it sends nothing and writes the journal. Then `run` again.
- Listing in a journal's `"retired": ["0x..."]` an address its deploy key created that is none of the
  unit's roles, and adding an entry to `chains.unrecordedDeploys`.
- A refusal that says "a person must resolve it" or "a person must choose" has no safe default. Do not
  delete records or switch keys to get past it.

A node that a `check` certified stays done while the journal holds `checked`, whatever the chain holds.
After resetting a development chain, delete the network's journals and that chain's records under
`broadcast/`, or a rehearsal network's whole directory.

## Examples

Both run on Anvil, and CI runs them (`test/e2e/e2e.sh`). [`examples/token-vault`](examples/token-vault)
has one chain, a dependent unit, a dated step and `recover`. [`examples/two-chain`](examples/two-chain)
has two chains, a step on the second that reads the first, a date on the second chain's clock, and a
step per index.

MIT.

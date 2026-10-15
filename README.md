# sprue

sprue makes multi-step Foundry deployments repeatable, inspectable and recoverable. You declare the
steps, and what each one needs, in Solidity. `plan` prints the commands still to run and sends
nothing. `run` sends only the missing steps; on a network with a chain that is not local, it shows each
step's dry run and waits for you to type `yes`. A rerun finishes an interrupted deployment, and a rerun of a
finished one sends nothing. Steps may span chains, wait for a date, or wait for a fact on chain.

Each step is one `forge script` command. The graph orders the steps, and a journal per unit records
what landed, so a lost journal can be rebuilt from forge's records. How sprue compares with plain
`forge script` and other tools is in [DESIGN.md](DESIGN.md#prior-art).

v0.1: the API may change in any 0.x release. [DESIGN.md](DESIGN.md) holds the assumptions, invariants
and decisions; [SECURITY.md](SECURITY.md) what the guards check and what stays with you.

## A first local run

[`examples/token-vault`](examples/token-vault) is a complete project that CI runs. From a clone of
this repository:

```sh
cp -R examples/token-vault ../my-deploy && cd ../my-deploy
git init && forge install foundry-rs/forge-std Xanewok/sprue@v0.1.1
anvil &                                   # chain 31337 on :8545
export R=http://127.0.0.1:8545 DEPLOYER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
node lib/sprue/bin/sprue.mjs plan local vault.check   # the next commands; sends nothing
node lib/sprue/bin/sprue.mjs run local vault.check    # deploys, checks, funds, checks
```

The first `plan` prints:

```
# chain l2 31337 local
forge script script/deploy/units/token/DeployToken.s.sol:DeployToken --sig 'deploy(string)' local --rpc-url $R --sender $DEPLOYER
forge script script/deploy/units/token/DeployToken.s.sol:DeployToken --sig 'check(string)' local --rpc-url $R --sender $DEPLOYER
# then plan again vault.deploy
```

The vault needs the token's address, so the plan stops until those two land. `run` sends them,
plans again, and repeats; afterwards the same `plan` prints `# done` for all five steps and a second
`run` sends nothing. The example's [README](examples/token-vault/README.md) explains each step, and
then loses a journal and rebuilds it.

## The model

- **Unit**: a Forge script, `Deploy<Name>.s.sol`, that inherits `Unit`, deploys and checks a few
  related contracts, and keeps one journal.
- **Step**: an external function of a unit, `fn(string network)`, with an id such as `token.deploy`:
  the unit, a dot, a name. Each step runs as its own `forge script` command.
- **Role**: a contract a unit deploys, named by a string such as `"token"`: a journal key, not an
  access-control role.
- **Journal**: `deployments/<network>/<unit>.json`, committed: each role's address, deployer, nonce,
  code hash and build metadata.
- **Certificate**: the `checked` object a unit's `check` step writes into its journal. It marks done
  the unit's steps without `.due` that `check` follows; other units read its addresses from it.
- **Graph**: a script that inherits `FileGraph` and registers the units. Steps declare `.needs(...)`;
  the graph orders them.
- **plan / run**: `plan` prints the commands a target still needs and sends nothing; `run` sends
  them, plans again, and stops when the target is done.

## Install

```sh
forge install foundry-rs/forge-std Xanewok/sprue@v0.1.1
```

The remapping is `sprue/=lib/sprue/src/` and the runner `node lib/sprue/bin/sprue.mjs`. With npm
(`npm i -D @xanewok/sprue`) they are `sprue/=node_modules/@xanewok/sprue/src/` and `npx sprue`.
Below, `sprue` means either. It needs Node 18 or later, `git`, `cast` and `forge` 1.8 or later
(CI pins v1.8.5). It starts no shell; Windows without WSL is not yet tested.

## Your own project

1. Copy `foundry.toml`, `sprue.json` and `.gitignore` from the example. `sprue` runs from any
   directory below `sprue.json`, and refuses unless git ignores `<rehearsal>/` and `<rehearsal>-x/`.
2. Add `deployments/<network>/network.json`, naming the network's chains: `{"chains":{"l2":{"id":31337}}}`.
3. Write a unit per directory under `script/deploy/units/<unit>/`; the example's
   [`DeployToken.s.sol`](examples/token-vault/script/deploy/units/token/DeployToken.s.sol) is a
   template. The directory, `_unit()` and every step id's prefix must be the same name. A deployed
   contract `<Name>` sits alone in `<Name>.sol`. Every step needs a done rule: a `<fn>Due` view
   (`.due(...)`), or a `check` step of the same unit that reaches it through `.needs(...)`.
4. Register the units in the graph script, whose contract is named like its file:

   ```solidity
   pragma solidity ^0.8.27;

   import {FileGraph} from "sprue/FileGraph.sol";
   import {DeployToken} from "./units/token/DeployToken.s.sol";

   contract DeployGraph is FileGraph {
       constructor() {
           _add(address(new DeployToken()), "script/deploy/units/token/DeployToken.s.sol:DeployToken");
           _validateGraph();
       }
   }
   ```

5. Save the graph: `sprue json > script/deploy/graph.generated.json`. Repeat this whenever you
   add, rename or rewire a step: `plan` and `run` look targets up in this file, and refuse one it
   lacks. `sprue list` prints the targets, the nodes nothing depends on.
6. Plan: `R=<rpc> sprue plan <network> <target>`, where `R` is the RPC of the network's default
   chain. It sends nothing, so anyone may run it.
7. Run: `R=<rpc> DEPLOYER=<address> sprue run <network> <target>`. `DEPLOYER` sends the steps
   that name no sender. On a network whose chains are all in `chains.local`, it runs unattended.
   On any other network a person runs it at a terminal, signing with one of `--account`,
   `--ledger` or `--trezor`, from a clean git checkout, and types `yes` for each step after seeing
   its dry run; [SECURITY.md](SECURITY.md) lists what it compares meanwhile.
8. Commit each step's journal and `broadcast/` records (the step prints the `git add`). The records
   are what `recover` reads, so never git-ignore a public chain's.
9. When a run on a live chain ends done or waiting, it offers a git tag `deploy/<network>/<unit>`
   for each unit whose check passed, at the commit its journal records, and then its push. A tag never moves,
   and a remote tag is never overwritten. A journal that records a dirty tree or several commits gets
   no tag. A failed push prints its retry command and keeps the run's status.

`sprue --help` lists the flags and the exit codes. Two flags are a person's decision, never a
way past a refusal: `--allow-dirty` starts on a dirty tree, and is refused on a live chain;
`--unsafe-unexpected-deployer` lets a deploy step send with a key other than the pinned `deployer`.
Before each send the runner checks `forge config --json`: forge must keep the records where the units
read them, and a rehearsal's resume data in its own directory. A `foundry.toml` setting or an
inherited variable that moves either path is refused.

## Rehearse

`sprue rehearse <network> <target>` runs what `run` would send on Anvil forks it starts, in
`<paths.rehearsal>-<network>`, a fresh copy of the files directly in `deployments/<network>/`:

```sh
R=<rpc> sprue rehearse mainnet vault.check     # forks, runs, stops the forks; the copy stays as the report
```

Each chain forks from `R` (the default chain only), else its `rpc` alias, else `<CHAIN>_RPC`, at the
latest block or `--block [<chain>=]<n>`; a chain in `chains.local` with none of these starts empty. The
copy keeps the journals, whose `checked` keeps what landed done without reading the fork, and drops the
aliases, so every command reads a fork.
Senders are impersonated: `DEPLOYER` (else the pinned `deployer`) and each `.by(...)`. No key signs, so a
signer flag is refused, and so is a `.env` that names a keystore; so is an `eth_rpc_url` that forge
resolves, which it would send to instead of the forks. It runs unattended, on a dirty tree too
(the journals record it), and moves each fork's clock to the next date. The forks stop at the end and on
Ctrl-C. `--keep` leaves them running and prints their `R=` and `<CHAIN>_RPC=` lines, until the next
`rehearse` of the network or `sprue rehearse --stop <network>`; a kept fork that does not answer is taken
as stopped. Every `rehearse` starts over, one at a time per network, and refuses an existing copy
without its `.sprue/`.

A rehearsal shows what Anvil reproduces. With `--block` before a landed unit's deployment, its copied
journal still says done; a bridge message between forks is never delivered.

## Configuration

`sprue.json` has exactly the keys `paths` and `chains`:

- `paths.graph`, `paths.units`, `paths.deployments`: the graph script, the unit directories (one
  `Deploy*.s.sol` each), and the network directories. Plan lines carry the paths unquoted, so
  each path must be a nonempty string using only `A-Z a-z 0-9 _ . / -`.
- `paths.rehearsal`: `<paths.deployments>/<name>`. A network of that name or `<name>-<suffix>` is a
  rehearsal network. An attended run on it requires Anvil or a `chains.local` id on every chain,
  because its journals and records are git-ignored. Its commands keep forge's records and resume
  data in `<network>/broadcast` and `<network>/cache`, so that a fork that keeps a public chain id
  never touches the real chain's `broadcast/` or `cache/`, and the real run's `--resume` never sends
  the rehearsal's transactions. A send or a dry run without that `FOUNDRY_BROADCAST=…
  FOUNDRY_CACHE_PATH=…` prefix is refused, the graph's own `plan` and `rehearse` included.
  `sprue plan` adds it; `sprue rehearse` stages `<paths.rehearsal>-<network>`, and the graph's
  `rehearse` takes the prefix of its staged copy `<paths.rehearsal>-rehearse-<network>`.
- `chains.default` (optional): the chain of a step without `.on(...)`. Without it, a network of
  one chain uses that chain.
- `chains.local` and `chains.test`: chain ids of development and test chains. Any other is live.
- `chains.unrecordedDeploys`: `{"<chain id>": "<reason>"}` turns off the nonce fence on that live
  chain, for a deploy key that already deployed outside the graph. Leave it `{}` otherwise.

In `network.json` a chain may name an `"rpc"` alias from `foundry.toml`; without one, a chain other
than the default is read from `<CHAIN>_RPC`. A top-level `"deployer": "0x..."` pins the deploy key.

## When a run refuses

Each refusal names its remedy. These need a person:

- A lost journal makes its deploy step refuse. If the journal was ever committed, restore it from
  git. Otherwise run the `recover` command the refusal prints, if any, with the build and inputs that
  made the deployment; it sends nothing and writes the journal. Then `run` again.
- Listing an address that is none of the unit's roles in the journal's `"retired": ["0x..."]`, and
  adding an entry to `chains.unrecordedDeploys`.
- A refusal that says "a person must resolve it" or "a person must choose" has no safe default: do
  not delete records or switch keys to get past it.

One refusal has a cause the message cannot see: a node a `check` certified stays done while the
journal holds `checked`. After resetting a development chain, delete the network's journals and
that chain's records under `broadcast/`, or a rehearsal network's whole directory.

## Examples

Both run on Anvil, and CI runs them (`test/e2e/e2e.sh`).

- [`examples/token-vault`](examples/token-vault): one chain, a dependent unit, a dated step, `recover`.
- [`examples/two-chain`](examples/two-chain): two chains, a step on the second that reads the first, a
  date on the second chain's clock, and a step per index.

MIT.

# Guide

How to set up and operate sprue. The [README](README.md) says what sprue is and how to install it;
[DESIGN.md](DESIGN.md) says why it has this shape, and [SECURITY.md](SECURITY.md) what its guards check.
`sprue` below is the runner: `node lib/sprue/bin/sprue.mjs`, or `npx sprue` with npm.

## Concepts

- **Unit**: a Forge script `Deploy<Name>.s.sol` that inherits `Unit` and holds the steps for a few
  related contracts. Each contract it deploys or reads is a **role**, declared once by how its address
  is made (`create`, `create2`, `extern`) and named by a string such as `"token"`; the journal keeps its
  facts under `<role>*` keys (`token`, `tokenNonce`, `tokenTx`).
- **Journal**: `deployments/<network>/<unit>.json`, committed: each role's address, deployer, nonce
  and code hash, and the path of its build metadata file beside it.
- **Step**: an external function of a unit that takes the network name (and an index, for a step per
  index), with an id such as `token.deploy`. Each step runs as its own `forge script` command.
- **Probe**: how `plan` judges a step that has no `Due` view: it runs the step as its sender and
  reverts its EVM state. The step is due at its first `_startBroadcast()` or journal write, done if it
  returns, and waits with its own reason if it reverts. Cheatcode state stays, as after a `Due` view:
  the clock, the selected fork, and a file written other than through `_put`.
- **Graph**: a script that inherits `FileGraph`, registers the units, and orders their steps by
  `.needs(...)`.

## Your own project

**On Windows, before you clone,** run `git config --global core.autocrlf false`, which applies to all
your repositories. Otherwise Git for Windows converts line endings as it checks files out: the files
then differ from the commit, the build is not the commit's, and an attended `run` refuses.

1. Copy `sprue.json` and `.gitignore` from the example, and merge its `foundry.toml` into yours: the
   `fs_permissions` and the `[rpc_endpoints]` aliases (its `src = "script"` suits only the example).
   `sprue` runs from any directory below `sprue.json`, and refuses unless git ignores
   `<paths.rehearsal>/` and `<paths.rehearsal>-x/`.
2. Add `deployments/<network>/network.json`, which gives each chain its id and an `rpc` alias from
   `foundry.toml`'s `[rpc_endpoints]`: `{"chains":{"l2":{"id":31337,"rpc":"local"}}}`.
   `"deployer"` pins the key that sends. A change of the pin is not supported: a role an earlier key
   created is refused.
3. Write one unit per directory under `script/deploy/units/<unit>/`, with the example's
   [`DeployToken.s.sol`](examples/token-vault/script/deploy/units/token/DeployToken.s.sol) and
   [`DeployVault.s.sol`](examples/token-vault/script/deploy/units/vault/DeployVault.s.sol) as templates.
   Declare each role once, in an `internal pure` function: `create(name, artifact)` for a CREATE by the
   deployer, `create2(name, artifact, key)` for a CREATE2 at the address that `<unit>.input.json` gives
   under `<key>.address`, with `<key>.salt`, and `extern(name, key, codeHash)` for a contract the unit did
   not deploy, at the input's `<key>`. `artifact` is a contract's name, in a source file of the same name.
   `.args(...)` gives the constructor arguments, as bytes or as a function that builds them from the
   inputs and other roles. `.ensure(fn)` runs `fn(address, args)` on every proof, and reverts on what later
   transactions can change, such as an admin or a proxy's implementation. `.unit("<unit>")` is the role as
   other units read it with `_at`. A role kept in a state variable puts the code its functions reach into
   the unit's creation code too, which can make the graph too large for forge to deploy against a node.
   List the unit's roles in `_roles()`, in the order its `recover` journals them. `contract X is Unit,
   Recovers` adds a `recover` step that rebuilds a lost journal of those roles.
   Write each step as `function deploy(string calldata network) external step(network) { ... }`.
   `_deploy(role)` sends a role or proves its reuse, and `_at(role)` proves it without a send:

   ```solidity
   function deploy(string calldata network) external step(network) {
       _deploy(pool());
       _deploy(router()); // router's .args read _at(pool())
   }

   function check(string calldata network) external step(network) {
       _at(pool());
       require(Router(_at(router())).pool() == _at(pool()), "router reads another pool");
       _endCheck();
   }

   function pool() internal pure returns (Role memory) {
       return create("pool", "Pool").args(abi.encode(uint256(30)));
   }

   function router() internal pure returns (Role memory) {
       return create("router", "Router").args(_routerArgs).ensure(_routerOwned);
   }

   function _routerArgs() internal returns (bytes memory) {
       return abi.encode(_at(pool()));
   }

   function _routerOwned(address router_, bytes memory) internal view {
       require(Router(router_).owner() == _requiredAddress(_unitInput(), "owner"), "router's owner changed");
   }
   ```

   Each `_deploy` journals as it sends, so a refusal at a later role leaves the earlier ones sent: read
   every input a later role needs before the first `_deploy`.
   `_endCheck()` ends a `check` step: it refuses unless the step proved every role of `_roles()`, so a
   `check` calls `_at` for every role, even one it asserts nothing about, and it journals each deployed
   role's receipt. A `check` is done while what it asserts holds: a probe runs it at every plan, and it is
   due only while a receipt is unrecorded. A role the unit uses must be in `_roles()`. Where
   `network.json` pins a `deployer`, only the pin sends a CREATE role, and only the pin's CREATE roles are
   proven. A CREATE2 role is proven whoever sent
   it, so its `.ensure` checks what its sender decides, such as an owner set from `tx.origin`. Another
   unit's role comes from `_at(OTHER())`, after `.needs("<unit>.deploy")`, when its code fixes what the
   step reads; for what that unit configured after the deploy, `_at(OTHER())` and a read of the contract
   in the step, after `.needs("<unit>.check")`.
   `_send(target, call)` sends a call the step decided on itself; guard it with that decision, or the
   step is always due and every `run` sends it again. A step is judged by a probe once everything it needs
   is done, so it must decide its own work before it sends: read the chain and the journal, and call `_startBroadcast()` only to send.
   A step that opens the broadcast before it decides is always due, and `run` stops when its plan
   repeats. Use `vm.startBroadcast` only through `_startBroadcast()`: a probe refuses forge's
   cheatcode. A probe journals no receipt, so a decision must not read `<role>Tx` or `<role>Block`.
   `_want(holds, target, abi.encodeCall(...))` sends a call only where `holds` is false, in order, so a
   later want sees what an earlier one sent; end the step with `_done()`, which closes the broadcast and
   reports whether the step sent. A `<fn>Due` view, as in `_step(id, this.fn, this.fnDue)`, replaces the
   probe for a step whose decision is cheaper to state apart.
4. Register the units in a graph script whose contract is named like its file: its constructor calls
   `_add(address(new DeployToken()), "<path>:DeployToken")` for each unit, then `_validateGraph()`, as in
   the example's [`DeployGraph.s.sol`](examples/token-vault/script/deploy/DeployGraph.s.sol).

5. Save the graph beside its script: `sprue json > script/deploy/graph.generated.json`. Save it again
   whenever you add, rename or rewire a step, because `sprue mermaid [target]` draws this saved file;
   `plan`, `run` and `rehearse` read the graph itself. `sprue list` prints the targets, the nodes
   nothing depends on.
6. Plan with `sprue plan <network> <target>`, which reads the default chain's `rpc` and sends nothing.
7. Run with `sprue run <network> <target>`. The deployer sends the steps that name no sender: `DEPLOYER`,
   else `network.json`'s pinned `deployer`, else the run's own signer. The run prints it and refuses at
   the start if it cannot sign as it. On a network whose chains are all in `chains.local`, the run is
   unattended: it sends unlocked on Anvil, as any account the node lists, and signs with `KEY` (Anvil's
   dev key if unset) on another node. On any other network a person runs it at a terminal, with no `CI`
   variable, from a clean git checkout, signing with exactly one of `--account <name>`, `--ledger` or
   `--trezor`. There a step that another account sends is refused, and each step is sent only after
   `yes` is typed at its dry run.
8. Once the run stops, commit each step's journal, metadata and `broadcast/` records; each step prints
   its `git add`. An attended run refuses a commit made while it waits for `yes`. `recover` reads the
   records, so never git-ignore a public chain's.
9. When a run on a live chain ends done or waiting, it offers an annotated tag `deploy/<network>/<unit>`
   for each unit whose journal is stamped with a live chain, at the commit its journal records, and to push it. Tags never
   move and are never overwritten; a journal that records a dirty tree or several commits gets no tag. A
   failed push prints its retry command and keeps the run's status.

Two flags are a person's decision, never a way past a refusal. `--allow-dirty` starts on a dirty tree
and is refused when any chain is live. `--unsafe-unexpected-deployer` lets the pinned `deployer`'s steps
send as `DEPLOYER`, or as the run's own signer when it cannot sign as the pin. `sprue --help` lists the flags and the exit codes.

A unit's directory, its `_unit()` and the prefix of its step ids are one name, and a contract `<Name>`
that it deploys is declared in the project's only file named `<Name>.sol`. The typed forms
`_step(id, this.fn)`, `_step(id, name, this.fn, i)` and their forms with a `Due` view after `this.fn`
let the compiler check each function and its view. The selector forms, such as
`_step(id, X.fn.selector)`, remain for other signatures, and [`src/graph/Step.sol`](src/graph/Step.sol)
holds the other builders. A unit pins every contract it reads but does not deploy, by code hash or by
behaviour, in its own checks.

## Rehearse

`sprue rehearse <network> <target>` runs what `run` would send on Anvil forks that it starts, in
`<paths.rehearsal>-<network>`, a fresh copy of the files directly in `deployments/<network>/` that stays
as the report. Each chain forks from its `rpc` alias at `--block [<chain>=]<n>`, else at the latest
block. The copy's `network.json` names each fork's loopback URL as its chain's `rpc`. Every step is
judged on the fork, so a `--block` before the deployment shows the deployment as not done.

Senders are impersonated: `DEPLOYER` (else the pinned `deployer`) and each `.by(...)`. No key signs, so
a signer flag is refused, as are a keystore that `.env` names and the `.env` and `foundry.toml`
settings that `run` refuses. `rehearse` runs unattended and on a dirty tree, which the journals record,
and moves each fork's clock to the next date. A fork of a chain that
[`bin/chains.json`](bin/chains.json) lists takes that chain's deployed-code limit and twice it for init
code; each entry names its evidence. Other forks keep Ethereum's 24576 and 49152 bytes. The forks stop
at the end and on Ctrl-C; `--keep` leaves them running, named in the copy's `network.json`, until the
next `rehearse` of the network or `sprue rehearse --stop <network>`. A kept fork that does not answer
counts as stopped.

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
`.env`; an `eth_rpc_url` or a non-default `sender` in `foundry.toml`; and a build directory other than
`out` (any spelling of it), since the units read each artifact and its metadata there.

## When a run refuses

Each refusal names its remedy. These need a person:

- A lost journal makes its deploy step refuse. If the journal was ever committed, restore it from git.
  Otherwise run the `recover` command the refusal prints, if any, with the build and inputs that made
  the deployment; it sends nothing and writes the journal. Then `run` again.
- Listing in a journal's `"retired": ["0x..."]` an address its deploy key created that is none of the
  unit's roles, and adding an entry to `chains.unrecordedDeploys`.
- A refusal that says "a person must resolve it" or "a person must choose" has no safe default. Do not
  delete records or switch keys to get past it.

A probed step is judged on the chain every time, a `check` included.
`plan` prints `# warning` for a role whose journaled creation code this build does not make, as after a
source edit: the role keeps its deployment, and the warning says it runs code this build does not make. It
shows while one of the unit's nodes in the plan is not done; `plan --verbose` shows it for done units too.
So a finished target warns only with `--verbose`, and a done unit that another unit's pending step reads
is not warned of.
After resetting a development chain, delete the network's journals and that chain's records under
`broadcast/`, or a rehearsal network's whole directory.

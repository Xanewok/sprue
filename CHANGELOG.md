# Changelog

## Unreleased

Breaking: completion is decided only by live checks. The `checked` certificate is gone, and a journal's
`checked` object is ignored as completion; it still counts as evidence that a role landed, so a journal that
has one but no `<role>Tx` is refused a resend while its address shows no code. A `check` step ends with
`_endCheck()`, which refuses unless the step proved every role of `_roles()` and journals the receipts of
the deployed ones; a probe judges the step due only while a receipt is unjournaled and findable, so a rerun
of an unchanged deployment sends and writes nothing. Migrating a unit:

- `_certify()`, `_certify(_certificate().with...())`, `_certificate`, `_beginChecked`, `_certifyRole` and
  `Certificate` become `_endCheck()`. What a certificate carried (extra facts, `withCode`, `withAddress`)
  is read live by the steps that need it.
- `.doneByCheck()` is removed, and every step of a unit needs a probe or a `<fn>Due` view
  (`MissingDoneRule` otherwise). `graph.generated.json`'s `doneRule.kind` is `probe` for a unit that answers
  `IProbe.probe`.
- `_checked(role)` and `_checkedOptional(role)` become `_at(role)` for another unit's role (or `_atOther`
  in a view, which also reads an `extern` role from its unit's input; the journal's stamp must name the
  chain the step selected), a live read of what that unit
  configured, and, where the order matters, `.needs("<unit>.check")`. Nothing enforces that edge; a
  dependent that reads another unit's configuration reads it live.
- `_recordAbsent` and the generic replacement for an absent role are removed: a unit that allows a role to
  be absent decides it from its own input, and refuses once code appears.
- Removed with the certificate: `unitInputHash`, `_journalChecked`, `Step.byCheck`, and the export's
  `Node.certified` and `certifiedBy`.
- Plans read each chain a check reads, so a plan needs an RPC for each of them. `rehearse` no longer
  compares a copied journal with its fork, and the tag offer keys on a journal stamped with a live chain
  for a unit whose `<unit>.check` the last plan printed as done.

`plan` prints `# warning <unit>.json's <role> runs code that this build of <artifact> does not make; it
stays deployed, and no step replaces it` for each role of the target's units whose journaled creation code
differs from this build, after the `# chain` lines, while one of the unit's nodes in the plan is not done;
`plan --verbose` also prints them for done units. `run` prints each warning once and goes on.
A tool that reads plan lines must ignore `# warning`.

Roles: a unit declares each contract once, by how its address is made, in an `internal pure` function:
`create(name, artifact)`, `create2(name, artifact, key)` (the input's `<key>.salt` and `<key>.address`) or
`extern(name, key, codeHash)`, with `.args(bytes)` or `.args(fn)` (a role given both is refused by name),
`.ensure(fn)` and `.unit(unitName)`. A step written `external step(network)` calls `_deploy(role)`, which
sends the role or proves its reuse, `_at(role)`, which proves it without a send, and `_endCheck()`, which
ends a `check` once the step proved every role of `_roles()`; a role outside `_roles()` is refused. A role is proven
by the identity its journal records: a CREATE by its recorded deployer and nonce (the pin, with a known creation
transaction); a CREATE2 by the factory under its
recorded salt and initcode hash, not this build's; an extern by its pinned code hash. Its recorded arguments
must be the declared ones and its `.ensure` must pass; another unit's role is proven by its identity and code.
A source edit after a deployment orphans
nothing, and `plan` warns of it. Where `network.json` pins a deployer, only the pin sends a declared CREATE
role, whatever `--unsafe-unexpected-deployer` says: a CREATE address follows from its sender. A CREATE2 role
is proven whoever sent it. `contract X is Unit, Recovers` adds a `recover(string)` derived from `_roles()`,
telling roles of one artifact apart by their arguments; `_onRecover` adds a unit's own keys. It is opt-in: its
recovery code adds about 49 KB to a unit's initcode. `_send(target, call)` sends a call the step decided on
itself.

Breaking: `Roles` adds `_deploy(Role)`, `_at(Role)`, `_endCheck()` and the non-virtual `_send(address,bytes)`
and `_send(address,uint256,bytes)`: a unit's own function of one of these names with the same parameters no
longer compiles, and a unit's own `_deploy` or `_at` passed as a function pointer is now ambiguous. A reused
`_deployRoleCreate2` role must also have its recorded initcode hash and salt give its address, and its
recorded arguments be the step's.

Breaking: the deploy API before roles is deleted: `_deployRole`, `_recover`, `_recovering` and the 4-argument
`_createToRecover`. A unit declares its contracts in `_roles()` and deploys them with `_deploy(role)`;
`contract X is Unit, Recovers` gives it `recover`.

Fixed: a deploy step's probe for a role its journal lacks ran the stray guard, which reads every script's
records on the chain, at a gas cost that grew with the square of their size: 24 records of 160 kB cost 167M,
so a probe ran out of gas. The guard now asks once per run whether it names the artifact, and frees each
record that holds none; the same probe costs 2.9M.

Fixed: proving a CREATE role whose journal has no `<role>Tx` read every script's broadcast records, twice,
so its gas grew with every unit and run: with 24 records of 100 kB one `_at` cost 175M gas, and a probe ran
out of gas, which `plan` reported as `# cannot reach <step>: 0x`. It now reads only the unit's own script's
records, its runs on this chain (`<records>/<script file>/<chain id>/`) and its multi-chain runs
(`<records>/multi/<script file>-*/`), for a CREATE only (409k gas there), and searches the chain for a role
another script created. `Unit._deployScript()` is virtual, for a unit outside `<paths.units>/<unit>/`.

Fixed: a role whose constructor reads the block, such as an immutable set to `block.timestamp`, was refused
on every run after its send ("<role>'s code differs from <unit>.json"): the journal holds the code hash of
forge's simulation, which runs in an earlier block than the send lands in. The unit's own proof of the role
now takes the landed code when exactly the journaled initcode made it: a CREATE2 role's address commits to
that initcode, and a CREATE role's creation transaction must have sent it. Its next step run or `check`
journals that code's hash; until then, another unit's `_at` of the role still refuses.

Fixed: a CREATE role's constructor arguments were proven against its journal's `<role>Args` only, so an
edit that matched them to a changed input passed while the contract held what its creation sent. The
unit's own proof of the role now requires that its creation transaction created it and sent its declared
arguments, and refuses otherwise ("<role>'s creation sent other constructor arguments than its input",
"<role>Tx in <unit>.json did not create <role>"). It costs two RPC reads per proof of a role with a known
transaction.

Fixed: `plan` no longer fails with `Failed to deploy script: execution reverted` on a node whose block gas
limit is below what creating one unit costs (about 30M gas, mostly its code). Forge runs each unit creation
and each probe of the graph as a transaction of its own, capped at that limit; the graph's commands now pass
`--disable-block-gas-limit`, as the graph never sends.

Fixed: `run` stops (exit 5) when its next plan holds a step it just sent. Before, it compared the whole plan,
so when another step of the same plan turned done, it sent a step again that a lagging RPC still showed as
due, and the node refused the transaction ("nonce too low").

`_deployRoleCreate2(journal, role, artifact, args, salt, at, authenticate)` is a deploy step for a role
the CREATE2 factory creates at the input's `at` for `salt`. A journaled role that landed is proven by its
recorded salt and code, then `authenticate`. Otherwise this build with `args` must land at `at`: a role
with code there and no journal entry is adopted, and a pending send is resent. It refuses a journal whose
address or salt differs from the input's, and code at `at` that another build or input made.

Fixed: a role whose receipt or check is journaled but whose address shows no code is refused, as a
lagging RPC or a reset chain, instead of resent or replaced. Before, the stale `checked` entry vouched for
a resent contract with the same code.

For tests, `unit.trustTestCreationOf(journal, role)` trusts one role's journaled intent as its creation in
this run.

`_inputFile(unit)` reads another unit's input file as an `Input`, and `_decided`, `_inputUint` and
`_requiredAddress` take one, so that a refusal names the file read.

`_recorded(unit, role)` reads another unit's role before its `check`: the journal must record it on this
chain, and its code must have the recorded hash.

`_want(holds, target, value, call)` sends `value` wei with `call`; with an empty `call`, a plain
transfer, which may go to an address without code.

Breaking, for tests: a creation proof that finds no transaction now refuses in a test as in a script.
A test that relies on forge keeping no transaction history calls `unit.trustTestCreations()`.
For tests, `Probes.due(unit, step, sender)` judges a step as the plan does: true while due, false once
done, and the step's own revert otherwise.

`plan` judges a step that has no `Due` view by running it as its sender in a probe that reverts its EVM
state: the step
is due at its first `_startBroadcast()` or journal write, done if it returns, and waits with its reason
if it reverts. `Due` views stay as the explicit form. A step that calls `vm.startBroadcast` directly waits until it calls
`_startBroadcast()` or gets a `Due` view. The export's `doneRule` has the kind `probe`.

`_want(holds, target, call)` sends `call` in the step's broadcast unless `holds`. `_startBroadcast()`
opens a broadcast only when forge has none open, and `_done()` closes it and reports whether the step
created a transaction, from the broadcaster's nonce.

A CREATE role's creation is proven once per forge run: a later proof of the same address and arguments on
the same chain reads no transaction or receipt again.

Fixed: a done step behind a date not yet reached printed `# not before`, from a gate view, or stopped the
plan, from an input date, so `run` exited 4 or warped the clock for a step with nothing to send. A done
step now has no date line; only a step still to send waits for its date.

Fixed: a predicate behind a gate view's date that held before the date was read as met, so `rehearse`
and the test interpreter sent its dependents early. A predicate is now judged only once its date is
reached, whatever its date's kind: before it, `plan` prints `# not before` and `# then plan again`.

Fixed: `_recordReceipt` finds a CREATE's transaction on the chain, by the journal's deployer and
nonce, when no broadcast record holds its receipt, as after a killed forge. Before, the role had no
`<role>Tx` until the records came back.

## 0.1.5

Breaking: a signal to `rehearse` exits with 128 plus the signal's number, as it does for `run`: SIGTERM
exits 143, not 130.

`run` and `rehearse` refuse to start (exit 2) while another run of the same network, or a forge that it
started, still runs. `rehearse` takes its copy's lock before it touches the copy, and so does a `plan` of
a copy, whose simulations write its journals. Before, both runs reached forge, and the later one failed
inside it or stopped at exit 3. A crash needs no cleanup: the lock replaces the rehearsal copy's
`.sprue/lock`, which a crash left for a person to remove.

A signal (SIGINT, SIGTERM, SIGHUP; SIGBREAK on Windows) to `run` or `rehearse` stops the forge that
runs and waits for it to exit. Before, a signal to `run` ended it alone and left its forge sending, or a
dry run writing journals, with no lock held.

Fixed: `plan`, `run` and `rehearse` read the graph itself, not the saved `graph.generated.json`, to judge
a target, and to choose the journals that an
attended run leaves out of its git status and offers tags for. A target the graph lacks exits 2 with one
line, and a rehearsal checks every journal of its copy. Only `mermaid` reads the saved file.

Fixed: `run` refuses a command whose forge build goes elsewhere than `out/` (through `foundry.toml`,
`FOUNDRY_PROFILE` or `FOUNDRY_OUT`), because the units read their artifacts from `out/`.

Fixed: a role whose recorded address has no code, as an RPC that lags behind the chain shows a role it
just deployed, is refused with "<role> at <address> has no code: if the RPC lags behind the chain, run
again once it shows the deployment". Before, `_requireRecordedCode` said that the role's code differs
from the journal, and `_checked` said only "<role> has no code".

Fixed: `plan`, `run` and `rehearse` refuse a plan that would stop at a step with a `Due` view or a
predicate that waits for a step only its unit's `check` marks done, when the plan sends no such `check`
before it. Before, `run` sent the earlier steps and then exited 5 with "plan is unchanged after sending
it", and `rehearse` passed. Give the earlier step a `Due` view, or plan such a check first.

[ROADMAP.md](ROADMAP.md) gains a "Known gaps" section: behavior that sprue does not yet refuse or fix.

## 0.1.4

Breaking: `run` and `rehearse` refuse at the start, before any send, a `DEPLOYER` that differs from
`network.json`'s pinned `deployer` unless `--unsafe-unexpected-deployer` is passed, and refuse that flag
on a network with no pin, where it had no effect. Before, a mismatch was refused only at the first CREATE,
after earlier steps may have sent.

`run` and `rehearse` default `DEPLOYER` to the pinned `deployer`. Without a pin, `run` sends as its own
signer: an attended run's wallet, an unattended run's `KEY`, else Anvil's dev key, so a local run no
longer needs `DEPLOYER`. `rehearse` still needs `DEPLOYER` or a pin. `run` refuses at the start a
deployer it cannot sign as, and both print `deployer <address>, from <source>` on standard output. With
`--unsafe-unexpected-deployer` the pin's steps send as `DEPLOYER`, or as the run's signer when the run
cannot sign as the pin; a `DEPLOYER` that a person set is never replaced.

The reference moved from `README.md` to `GUIDE.md`; a link to a README section needs the new file.

## 0.1.3

Breaking: each chain of `network.json` must name an `rpc` alias of `foundry.toml`'s `[rpc_endpoints]`,
the one RPC configuration, which forge, cast and anvil resolve with `.env`. `R`, the `<CHAIN>_RPC`
variables and the `<CHAIN>_RPC=$<CHAIN>_RPC` command prefix are gone: commands print each chain's alias.
A command line's `--rpc-url` must be one of its network's chains. `rehearse` names each fork's loopback
URL in its copy's `network.json`, the only file that may hold a URL, and `--keep` no longer prints
variables. A chain in `chains.local` no longer starts as an empty Anvil: it forks its alias.

Breaking: `Graph._execute` is `_executeTarget`. The new `_executeNode(network, id)` runs one node as
`_executeTarget` would, without its needs, and sends its step even when it is done, so the unit's own
checks decide. Tests use it to run a node out of order on purpose. Both call `_unmetPredicate` once per
predicate until it is met: a driver that returned true without meeting it looped forever. Both read input
dates on the chain selected when they start, as `rehearse` did; a direct call used a stale chain.

`list`, `json`, `plan` and `run` show forge's compile lines on stderr while the graph script compiles,
instead of a silent wait: forge reports a compile on the stdout that the runner captures. Standard
output is unchanged, and a run with nothing to compile prints nothing more.

A unit step that broadcasts checks the RPC server it sends to, in the forge script itself: on a network that
is not a rehearsal one, a chain that `chains.local` does not list must not be served by Anvil, and on a
rehearsal network it must be. The runner checked only the RPC server it resolved itself, so a line run by hand,
or a `FOUNDRY_ETH_RPC_URL` that forge takes over `--rpc-url`, escaped the check. `forge script --resume`
sends its cached transactions without this check.

`run` refuses a line when `FOUNDRY_ETH_RPC_URL`, `FOUNDRY_SENDER` or `FOUNDRY_RPC_ENDPOINTS` (or a
`DAPP_` or `DAPP_TEST_` form, in any case) is set in the environment or `.env`, whatever the value: forge
and cast take these over the line's `--rpc-url` and `--sender`, or over the aliases they name, so the line
shown would not be the one that runs. It refuses an `eth_rpc_url` or a non-default `sender` in
`foundry.toml` too, as sprue's lines own both settings, and a line that selects its own forks names no
`--rpc-url`. `rehearse` drops the variables from its own environment and refuses them in `.env`,
and refuses a resolved `sender` too, as it already refused an `eth_rpc_url`.

An attended `run` without `DEPLOYER` sends as its signer, as forge does with `--account`, `--ledger` or
`--trezor`: `sprue run --account <name> <network> <target>`. A pinned `deployer` still refuses another
signer.

Typed step forms: `_step(id, this.fn)`, `_step(id, this.fn, this.fnDue)`, the indexed
`_step(id, name, this.fn, this.fnDue, i)` and `_until(id, name, this.fn)`. The compiler checks that each
function exists with the step's arguments and that a `Due` returns a bool; `steps()` becomes `view`. The
selector forms are unchanged.

`rehearse` gives a fork of a chain that `bin/chains.json` lists that chain's code-size limit. It lists
Robinhood Chain and its testnet, at 98304 bytes.

The tag offer skips a unit whose journal is stamped only with test or local chains, even when its network also names
a live chain that it reads.

A step's view or predicate whose file read or JSON parse fails, such as on a missing input file,
fails `plan`, `run` and `rehearse` with the node's id and the cheatcode's message. It no longer shows
as `# cannot reach`, which made a setup mistake end as a wait (exit 3). A failed `vm.rpc` stays a wait.

## 0.1.2

When an attended run on a live chain ends done or waiting, it offers an annotated tag
`deploy/<network>/<unit>` for each unit whose check the plan printed done, at the commit its journal records, and its push. A
rerun offers what is missing. An existing tag of another tree, a remote tag at another commit, a dirty
journal and several commits are reported, never tagged or overwritten. A failed push keeps the run's status.

`rehearse` refuses a fork that lacks the code a copied journal records, as at a `--block`
before the deployment.

`sprue rehearse <network> <target>` runs a target on Anvil forks it starts, in a fresh copy
`<paths.rehearsal>-<network>` of the network's files, as impersonated senders: no key signs, and a
signer flag, a keystore in `.env` or a resolved `eth_rpc_url` is refused. Each chain forks from `R`, its `rpc` alias or
`<CHAIN>_RPC`; `--block` pins a fork's block. It runs unattended, moves the forks' clocks to each date,
and stops the forks at the end; `--keep` leaves them running and prints their variables, until the next
`rehearse` or `rehearse --stop`. The examples name the rehearsal prefix `rehearsal`.

A rehearsal network keeps forge's records and resume data in `<paths.deployments>/<network>/broadcast`
and `<paths.deployments>/<network>/cache`: its commands, its units' printed commands and the runner's plan start with
`FOUNDRY_BROADCAST=` and `FOUNDRY_CACHE_PATH=` those paths, and its units refuse a send or a dry run
without them. A rehearsal on a fork that keeps a public chain id no longer leaves records that the real
run reads as a lost journal, or a snapshot or dry run that the real run's `--resume` sends. Before each
send the runner checks the paths that `forge config --json` resolves, so a `foundry.toml` setting or an
inherited variable cannot move them. An attended rehearsal requires Anvil or a `chains.local` id on
every chain. Every `sprue.json` path accepts only `A-Z a-z 0-9 _ . / -`.

## 0.1.1

The runner is `bin/sprue.mjs`, Node 18 or later with no dependencies, and replaces `bin/graph.sh`:
run it as `node lib/sprue/bin/sprue.mjs` (forge install) or `npx sprue` (npm). It needs no `sh` or
`jq` and starts no shell; Windows without WSL is not yet tested. A plan line becomes the argv of one
`forge script`, so a variable that holds whitespace is one argument instead of a refusal; an unset
variable in a line's arguments is refused.

## 0.1.0

First release: the deploy graph (`Graph`, `FileGraph`, `Unit`), the `graph.sh` runner and the
`@xanewok/sprue` npm package.

The journal format has no version field yet, and the API may change in a 0.x release.

The `v0.1.0` tag first pointed at an earlier commit. Moving from it: `ForgeBroadcasts.Create.at` is
now `addr` (`at` is a keyword from solc 0.8.36), and a `graph.sh` plan line must match the command
grammar in full.

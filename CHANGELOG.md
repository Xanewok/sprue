# Changelog

## Unreleased

`_inputFile(unit)` reads another unit's input file as an `Input`, and `_decided`, `_inputUint` and
`_requiredAddress` take one, so that a refusal names the file read.

`_requireJournaledCreate(journal, role, args)` holds a role's record to the step's arguments, the pinned
deployer and the CREATE address of its recorded nonce. It reads the journal only.

`_recorded(unit, role)` reads another unit's role before its `check`: the journal must record it on this
chain, and its code must have the recorded hash.

`_want(holds, target, value, call)` sends `value` wei with `call`; with an empty `call`, a plain
transfer, which may go to an address without code.

`_deployRole(journal, role, artifact, args, proof)` creates `artifact` from its initcode with `args`, so
a unit needs no `create` callback, and proves a reuse by `proof`.

Breaking, for tests: a creation proof that finds no transaction now refuses in a test as in a script.
A test that relies on forge keeping no transaction history calls `unit.trustTestCreations()`.
`_deployRole(..., create, Proof.WithArgs)` proves a reused role with `_requireCreatedWith`.
`_certificate(role, addr)` starts a certificate without journaling a receipt, for a contract the unit
did not deploy.

For tests, `Probes.due(unit, step, sender)` judges a step as the plan does: true while due, false once
done, and the step's own revert otherwise.

`_reuse(journal, role, args)` returns a role's recorded address for a step after its deploy step, once
its code is the journal's and its creation took `args` (`_requireCreatedWith`).

A `check` step builds its certificate with `_certify(_certificate(journal, role, addr).withCode("vault",
vault).withUint(...))`: `_certificate` journals the role's receipt and starts the certificate, each
`with...` adds a key, and `_certify` writes it on the role's code hash, prints it once and ends the step.

`_requireCreatedWith(journal, role, args)` proves a role's constructor arguments without this build's
code: the creation input must be code that hashes to the journal's new `<role>CreationCodeHash`,
followed by `args`. A role whose source changed after its deployment passes. A journal written before
that key has the input proven against `<role>InitcodeHash` and `args` against `<role>Args`.

`plan` judges a step that has no `Due` view by running it as its sender in a probe that reverts its EVM
state: the step
is due at its first `_startBroadcast()` or journal write, done if it returns, and waits with its reason
if it reverts. `Due` views stay as the explicit form. Breaking: in a unit that answers the probe, a
`check` certifies only itself and the steps marked `.doneByCheck()`; other steps it follows are now
judged by their probe. A step that calls `vm.startBroadcast` directly waits until it calls
`_startBroadcast()`, gets a `Due` view, or is marked. The export's `doneRule` has the kind `probe`.

`_want(holds, target, call)` sends `call` in the step's broadcast unless `holds`. `_startBroadcast()`
opens a broadcast only when forge has none open, and `_done()` closes it and reports whether the step
created a transaction, from the broadcaster's nonce.

`_requireCreatedFrom(journal, role, artifact, args)` proves that a role was created from this build's
artifact with the step's constructor arguments: it compares the creation transaction's whole input, as
the chain shows it, with the initcode. It reads only the transaction's hash from the journal, a
broadcast record or the chain. `_deployRole` without an `authenticate` argument runs it on a reused
role; with one, nothing changes. `_findCreationInput(journal, role)` returns that input for a unit
that compares it with something else.

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
a target, to compare a rehearsal's certificates with its forks, and to choose the journals that an
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

`_recordAbsent(obj, role, at)` records in a certificate that `role` has no code at `at`, and
`_checkedOptional(unit, role)` reads a role that may be absent: `(true, addr)` as `_checked` reads it, or
`(false, address(0))` while the recorded address still has no code. Code there since the check reverts,
so a dependent never builds on a stale absence. `_checked` refuses an absent role.

Fixed: a certificate no longer carries keys that an earlier check wrote in the same forge run.

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

The tag offer skips a unit certified only on test or local chains, even when its network also names
a live chain that it reads.

A step's view or predicate whose file read or JSON parse fails, such as on a missing input file,
fails `plan`, `run` and `rehearse` with the node's id and the cheatcode's message. It no longer shows
as `# cannot reach`, which made a setup mistake end as a wait (exit 3). A failed `vm.rpc` stays a wait.

## 0.1.2

When an attended run on a live chain ends done or waiting, it offers an annotated tag
`deploy/<network>/<unit>` for each certified unit, at the commit its journal records, and its push. A
rerun offers what is missing. An existing tag of another tree, a remote tag at another commit, a dirty
journal and several commits are reported, never tagged or overwritten. A failed push keeps the run's status.

`rehearse` refuses a fork that lacks the code a copied journal's check certifies, as at a `--block`
before the deployment, which the copied `checked` would otherwise show as done.

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

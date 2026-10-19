# Changelog

## Unreleased

A unit step that broadcasts checks the node it sends to, in the forge script itself: on a network that
is not a rehearsal one, a chain that `chains.local` does not list must not be served by Anvil, and on a
rehearsal network it must be. The runner checked only the node it resolved itself, so a line run by hand,
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

Breaking: each chain of `network.json` must name an `rpc` alias of `foundry.toml`'s `[rpc_endpoints]`,
the one RPC configuration, which forge, cast and anvil resolve with `.env`. `R`, the `<CHAIN>_RPC`
variables and the `<CHAIN>_RPC=$<CHAIN>_RPC` command prefix are gone: commands print each chain's alias.
A command line's `--rpc-url` must be one of its network's chains. `rehearse` names each fork's loopback
URL in its copy's `network.json`, the only file that may hold a URL, and `--keep` no longer prints
variables. A chain in `chains.local` no longer starts as an empty Anvil: it forks its alias.

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

# sprue

Deploy graphs for Foundry. A deployment is a graph of idempotent Solidity steps (units). Each step
sends only what the chain and its journal lack. You get:

- a readable plan: `plan` prints the exact commands that reach a target and sends nothing;
- sends you approve: an attended `run` shows each dry run and asks before every send;
- multi-chain graphs: a step runs on a named chain and may read others;
- gates: a step can wait for a date (`notBefore`, `gateView`), and a node can wait for a chain fact (`_until`);
- journals: what a unit deployed and the code each contract must keep, committed with the project;
- recovery: a lost plain-CREATE journal is rebuilt from the sender's broadcast record.

## Status

v0.1. 0.x, so the API will change.

## Install

```sh
forge install Xanewok/sprue@v0.1.0
```

Add the remapping `sprue/=lib/sprue/src/` and run the graph with `lib/sprue/bin/graph.sh`. Or:

```sh
npm i -D @xanewok/sprue
npx sprue plan <network> <target>
```

The runner is POSIX `sh` and needs `jq`, `forge` and `cast`. Windows: use WSL (a Node runner is not
released yet).

## Setup

1. Add the remapping `sprue/=lib/sprue/src/` (and `forge-std/=lib/forge-std/src/`) to `foundry.toml`.
2. Grant forge the paths the units read and write; with the layout below:

   ```toml
   fs_permissions = [
     { access = "read-write", path = "./deployments" },
     { access = "read", path = "./out" },
     { access = "read", path = "./broadcast" },
     { access = "read", path = "./script/deploy/units" },
     { access = "read", path = "./sprue.json" },
   ]
   ```

3. Write `sprue.json` at the project root. `graph.sh` runs from any directory below the nearest one
   holding it.
4. Git-ignore the rehearsal directories (`deployments/fork-test*/` for the file below); `graph.sh`
   refuses to run otherwise.
5. Write the graph script and the units (see below), then save the graph with
   `graph.sh json > script/deploy/graph.generated.json`, the file beside the graph script that
   `mermaid`, `plan` and `run` read to check a target's name.

## Layout

```
sprue.json                        paths and chain policy
script/deploy/DeployGraph.s.sol   lists the units
script/deploy/units/<unit>/       one directory per unit, holding exactly one Deploy*.s.sol
deployments/<network>/            network.json, <unit>.input.json, <unit>.json (journal)
```

`sprue.json` has exactly the keys `paths` and `chains`:

```json
{
  "paths": {
    "graph": "script/deploy/DeployGraph.s.sol",
    "units": "script/deploy/units",
    "deployments": "deployments",
    "rehearsal": "deployments/fork-test"
  },
  "chains": {
    "default": "l2",
    "local": [31337],
    "test": [11155111],
    "unrecordedDeploys": { "1": "why this chain has deploys no journal records" }
  }
}
```

`paths.graph` is the graph script's file; the contract in it is named like the file
(`DeployGraph.s.sol` holds `contract DeployGraph`). `paths.rehearsal` must lie under
`paths.deployments`: a network named `fork-test` or `fork-test-<suffix>` is a rehearsal, where a
development node may be used attended. `chains.default` is optional: the chain a step without `.on(...)`
uses, which every `network.json` must list; without it a network of one chain uses that chain, and a
network of several needs `.on(...)` on every step. `chains.local` are the chains `run` sends to
unattended. `chains.test` are the test chains, where test-only units may run. `chains.unrecordedDeploys`
maps a chain id to the reason its earlier deploys have no journal.

A network's `deployments/<network>/network.json` names its chains, for example
`{"chains":{"l2":{"id":31337}}}`; a chain may add `"rpc"`, a `foundry.toml` `[rpc_endpoints]` alias, and
without it a chain's RPC is read from `<CHAIN>_RPC` (`$R` for the default chain).

## Commands

| Command | Does |
|---|---|
| `graph.sh list` | the targets: nodes no other node depends on |
| `graph.sh json` | the graph from the units' code |
| `graph.sh mermaid [target]` | a flowchart of the graph, or of what `target` needs |
| `R=$RPC graph.sh plan <network> <target>` | the commands that reach the target; sends nothing |
| `R=$RPC DEPLOYER=$ADDR graph.sh run <network> <target>` | sends what `plan` prints, plans again, repeats |

On a local chain `run` is unattended. On any other chain it is attended: it needs a terminal, a clean
git checkout and one of `--account`, `--ledger` or `--trezor`. It asks `yes` before every step, and
refuses to send if the sender's nonces, git state or `.env` changed since the dry run. `graph.sh
--help` prints the usage and the exit codes (3: a node not reachable yet, 4: a date not reached,
6: no `yes`).

## A unit

A unit is a script that inherits `Unit`, names its journal in `_unit()` and lists its steps in
`steps()`. Each step is `fn(string network)`.

```solidity
contract DeployToy is Unit {
    function steps() external view returns (Step[] memory s) {
        s = new Step[](2);
        s[0] = _step("toy.deploy", DeployToy.deploy.selector);
        s[1] = _step("toy.check", DeployToy.check.selector).needs("toy.deploy");
    }

    function deploy(string calldata network) external returns (string memory) {
        string memory journal = _use(network);
        (, bool sent) = _deployRole(journal, "toy", "ToyPayload", abi.encode(1), _create, _authenticate);
        return _done(sent);
    }

    function check(string calldata network) external returns (string memory) {
        string memory journal = _use(network);
        address at = _requireRecordedCode(journal, "toy");
        _authenticate(at, abi.encode(1));
        _recordReceipt(journal, "toy", at);
        return _certifyRole(_beginChecked("toy", at), "toy", at);
    }

    function _unit() internal pure override returns (string memory) { return "toy"; }
    // _create deploys the contract; _authenticate reverts unless a reused contract matches the args.
}
```

A unit calls `_use(network)` before `_checked(...)`: `_checked` reads the directory `_use` selects.
Every step needs a done rule, `.due(...)` (a `<fn>Due(string)` view returning whether it still has work) or
a `check` step of the same unit that reaches it through `.needs(...)`; otherwise the graph refuses with
`MissingDoneRule`. Register the units in a script that inherits `FileGraph`, with
`_add(address(new DeployToy()), "script/deploy/units/toy/DeployToy.s.sol:DeployToy")` for each and
`_validateGraph()` last. A complete project is in `e2e/toy`.

`_deployRole` reuses a journaled deployment, resends a pending intent as the same transaction, or
sends a new one. `check` certifies the same-unit steps it reaches through `.needs(...)`. The
deployment layers are exercised by `test/ToyUnit.sol`; the step builders are in `src/graph/Step.sol`.

## Boundary

`src/` imports only forge-std and itself. Your project's contracts never need to be imported by
the library, and CI checks it.

MIT.

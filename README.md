# sprue

sprue runs a multi-step Foundry deployment from a graph of steps declared in Solidity. Each step is one
`forge script` command. `sprue plan` prints the commands that a target, a step id such as `vault.check`,
still needs, and sends nothing. `sprue run` sends them, plans again, and stops when the target is done.
On a chain outside `sprue.json`'s `chains.local`, such as a testnet or a mainnet, `run` signs with a
keystore or a hardware wallet, shows each step's dry run, and sends it only after you type `yes`.

Plain `forge script` with `--resume` finishes one interrupted broadcast of one script. It keeps no
record across scripts, so a finished script that runs again sends every CREATE again. In sprue each
unit, one deploy script, keeps a committed journal of what landed. A deployment of many scripts
across chains and weeks can be stopped, rerun, reviewed and recovered. How sprue compares with
Hardhat Ignition, treb, Cannon and others is in [DESIGN.md](DESIGN.md#prior-art).
Why sprue is shaped this way, from effect kinds to build-system theory: [MODEL.md](MODEL.md).

## What it does

- A rerun finishes an interrupted deployment, and a rerun of a finished one sends nothing. A lost
  journal is rebuilt from forge's `broadcast/` records with `recover`.
- A step can wait for a date or for a fact on chain. Before a future date, `run` stops with exit code
  4 unless you pass `--wait`; on Anvil it moves the clock.
- One network can span several chains, and a step on one chain can read what landed on another.
- A step that reads another unit's contract through `_at` re-reads its code first, and refuses if
  it differs from what that unit's journal records.
- Every command a plan prints is a plain `forge script` command that you can read, paste and run.
- `sprue rehearse` runs a target on Anvil forks of the real chains, with the senders impersonated.

## What it does not do yet

- Send through a Safe or a timelock: every sender of a real run signs with its own key.
- Wait for finality: a reorg can undo a step that the journal records
  ([SECURITY.md](SECURITY.md#limits)).
- Deliver a bridge message between forks in a rehearsal.
- Verify sources on Etherscan or Sourcify.
- Keep a stable API or journal format: any 0.x release may change them. [ROADMAP.md](ROADMAP.md) says
  what is planned.

## What sprue guarantees

Three layers own different kinds of correctness.

- **Your contracts** own protocol correctness. What must hold for funds, bindings between contracts or
  irreversible steps belongs in their constructors and functions: only code inside a transaction is checked
  atomically when the transaction lands.
- **sprue** owns the deploy process, and its guarantees are exact within the limits stated here:
  - A step is done only when its own check says so at the chain's head: its body would send nothing, or
    its `Due` view says it has no work.
  - A role, a named contract of the deployment, is deployed once on a live chain whose `network.json` pins
    the deployer, even after its journal is lost. [SECURITY.md](SECURITY.md#limits) names where this does
    not hold.
  - A role that `_deploy` or `_at` returns is proven against the chain. A CREATE role must
    be its recorded deployer's CREATE at its recorded nonce, and its creation transaction must have sent
    the declared constructor arguments. A CREATE2 role must be the factory's address for its journaled salt
    and initcode hash. An extern role must have its pinned code hash and, with `.at`, its canonical address; one declared `.optional` that the input calls `"absent"` must have no code at that address, which is proven again on every read. Two gaps remain: a CREATE2 role's
    arguments are compared with its journal only, and another unit's role is proven by its identity and
    code, not its arguments. An address that a step uses without a role is not checked.
  - A second run of a finished deployment sends nothing, unless the chain or its inputs changed in between.
- **Preflight checks** are everything else sprue checks: a role's `.ensure` check of a deployed contract's
  state and the assertions a unit's steps make about the protocol. They refuse early with a clear message,
  but they are approximate: they run on a simulation at one block, and the chain can change before the
  transaction lands.

[SECURITY.md](SECURITY.md) lists what each guard checks; [DESIGN.md](DESIGN.md#invariants) names the tests
that prove the invariants.

## Declaring steps

The example's vault unit declares its steps like this:

```solidity
function steps() external view returns (Step[] memory s) {
    s = new Step[](3);
    s[0] = _step("vault.deploy", this.deploy).needs("token.check");
    s[1] = _step("vault.fund", this.fund).needs("vault.deploy").notBefore("vault.openAt");
    s[2] = _step("vault.check", this.check).needs("vault.fund");
}
```

The vault waits for the token unit's check, sends `fund` only after the `openAt` date in its input file
`vault.input.json`, and checks itself last. `plan` judges `deploy` and `fund` by running them in a
probe: a step is due while it would still send. `check` is judged the same way: done while what it asserts holds.
[GUIDE.md](GUIDE.md) explains the concepts and how to set up your own project, rehearse, configure and
recover.

## Quick start

sprue needs Node 18 or later, `git`, `cast`, `forge` 1.8 or later (CI pins v1.8.5), and `anvil` for
`rehearse`. On Windows without WSL, CI runs the library's tests, `rehearse`, `run` and a rerun in
PowerShell, and a one-off check found cmd and Git Bash the same. An attended run asks its question on
the console: run it in PowerShell or cmd, or under Git Bash's mintty as
`winpty node lib/sprue/bin/sprue.mjs run …`. The lines that `plan` prints are bash syntax: run one by
hand in Git Bash. For a deep checkout, run `git config --global core.longpaths true` before you clone.

This runs [`examples/token-vault`](examples/token-vault), a complete project that CI runs:

```sh
git clone https://github.com/Xanewok/sprue && cd sprue
cp -R examples/token-vault ../my-deploy && cd ../my-deploy
git init && forge install foundry-rs/forge-std Xanewok/sprue@v0.1.5
anvil &                                   # chain 31337 on :8545
node lib/sprue/bin/sprue.mjs plan local vault.check   # the next commands; sends nothing
node lib/sprue/bin/sprue.mjs run local vault.check    # the token's two steps, then the vault's three
```

The first `plan` prints:

```
# chain l2 31337 local
forge script script/deploy/units/token/DeployToken.s.sol:DeployToken --sig 'deploy(string)' local --rpc-url local --sender $DEPLOYER
forge script script/deploy/units/token/DeployToken.s.sol:DeployToken --sig 'check(string)' local --rpc-url local --sender $DEPLOYER
# then plan again vault.deploy
```

The vault needs the token's address, so the plan stops until the token's deploy lands. `run` sends them
with `$DEPLOYER` as Anvil's dev key, the run's own signer here, and plans again until the plan prints
`# done` for all five steps, and a second `run` sends nothing.
The example's [README](examples/token-vault/README.md) explains each step, then loses a journal and
rebuilds it.

## Install

Install with `forge install foundry-rs/forge-std Xanewok/sprue@v0.1.5`. The remapping is
`sprue/=lib/sprue/src/` and the runner is `node lib/sprue/bin/sprue.mjs`. With npm
(`npm i -D @xanewok/sprue`) they are `sprue/=node_modules/@xanewok/sprue/src/` and `npx sprue`.

## Examples

Both run on Anvil, and CI runs them (`test/e2e/e2e.sh`). [`examples/token-vault`](examples/token-vault)
has one chain, a dependent unit, a dated step and `recover`. [`examples/two-chain`](examples/two-chain)
has two chains, a step on the second that reads the first, a date on the second chain's clock, and a
step per index.

[SECURITY.md](SECURITY.md) lists what the guards check and what stays with you, and
[CHANGELOG.md](CHANGELOG.md) what each release changed. MIT.

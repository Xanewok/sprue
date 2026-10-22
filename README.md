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

## What it does

- A rerun finishes an interrupted deployment, and a rerun of a finished one sends nothing. A lost
  journal is rebuilt from forge's `broadcast/` records with `recover`.
- A step can wait for a date or for a fact on chain. Before a future date, `run` stops with exit code
  4 unless you pass `--wait`; on Anvil it moves the clock.
- One network can span several chains, and a step on one chain can read what landed on another.
- A step that reads another unit's contract through `_checked` re-reads its code first, and refuses if
  it differs from what that unit's check certified.
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

## Declaring steps

The example's vault unit declares its steps like this:

```solidity
function steps() external view returns (Step[] memory s) {
    s = new Step[](3);
    s[0] = _step("vault.deploy", this.deploy, this.deployDue).needs("token.check");
    s[1] = _step("vault.fund", this.fund, this.fundDue).needs("vault.deploy").notBefore("vault.openAt");
    s[2] = _step("vault.check", this.check).needs("vault.fund");
}
```

The vault waits for the token unit's check, sends `fund` only after the `openAt` date in its input file
`vault.input.json`, and checks itself last. `deployDue` and `fundDue` return true while their step
still has work. `check` has none: it is done once it writes the certificate, the record of the unit's
addresses that other units read.
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
git init && forge install foundry-rs/forge-std Xanewok/sprue@v0.1.4
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

The vault needs the token's address, so the plan stops until those two commands land. `run` sends them
with `$DEPLOYER` as Anvil's dev key, the run's own signer here, and plans again until the plan prints
`# done` for all five steps, and a second `run` sends nothing.
The example's [README](examples/token-vault/README.md) explains each step, then loses a journal and
rebuilds it.

## Map

`sprue map > map.html` draws what a deployment created and how the contracts connect: one offline HTML
page with a step player, from forge's `broadcast/` records and the events in their receipts (owner, roles,
proxy admin, ERC-1967 implementation). It works in any Foundry project; `sprue map <network>` adds sprue's
role names and certificate-verified links. [MAP.md](MAP.md) has the details.

## Install

Install with `forge install foundry-rs/forge-std Xanewok/sprue@v0.1.4`. The remapping is
`sprue/=lib/sprue/src/` and the runner is `node lib/sprue/bin/sprue.mjs`. With npm
(`npm i -D @xanewok/sprue`) they are `sprue/=node_modules/@xanewok/sprue/src/` and `npx sprue`.

## Examples

Both run on Anvil, and CI runs them (`test/e2e/e2e.sh`). [`examples/token-vault`](examples/token-vault)
has one chain, a dependent unit, a dated step and `recover`. [`examples/two-chain`](examples/two-chain)
has two chains, a step on the second that reads the first, a date on the second chain's clock, and a
step per index.

[SECURITY.md](SECURITY.md) lists what the guards check and what stays with you, and
[CHANGELOG.md](CHANGELOG.md) what each release changed. MIT.

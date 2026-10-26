# Security

Report a vulnerability privately through GitHub: the repository's Security tab, "Report a vulnerability"
(a security advisory). Do not open a public issue for it.

## What the guards check

The guards are code in `bin/sprue.mjs` and `src/`; [DESIGN.md](DESIGN.md#invariants) names the test or
end-to-end scenario for each invariant.

- `run` executes only a command line in the grammar that `plan` prints, as one `forge script` with no
  shell. A variable it names is one argument, whatever it holds; an unset one is refused as an argument and
  passed empty as an assignment before `forge`.
- An attended send needs `yes` typed at the terminal. It refuses if, from before the dry run to the
  answer, the sender's nonce on any chain of the network, git HEAD, the lines of
  `git status --porcelain`, `.env` or `~/.foundry/foundry.toml` changed. The status leaves out the
  network's `<unit>.json` and `*.metadata.json` files, which the run writes, so a new file there is
  not seen; a status line names a path and its state, not its contents, so an edit to a file already
  modified or untracked is not seen either. A clean checkout at the start keeps that list short;
  `--allow-dirty` waives it, and is refused when any chain of the network is live.
- One `run` or `rehearse` of a network, or `plan` of a rehearsal copy, runs at a time: a second refuses
  while the first, or a forge the first started, runs. Each holds a file named by its pid in the git
  directory's `sprue-locks/<network>/`, and writes it before it reads the other files, so two runs that
  start together may both refuse but never both go on. A file whose process has exited is removed; if a
  new process gets that pid first, the run refuses and names the file to remove. A signal to the runner
  stops the forge that runs and waits for it to exit before the lock is released.
- A deploy step on a network that pins `deployer` sends only with that key, unless the run opts out
  with `--unsafe-unexpected-deployer`.
- A role the journal lacks is deployed only if no broadcast record of the chain holds a CREATE of its
  contract that landed or may land. On a live chain without a `chains.unrecordedDeploys` entry, it,
  or a role whose recorded deployment can no longer land, is also refused while a known deployer (the
  sender, the pin, any journal's deployer) has used more than 256 nonces, or has a CREATE with code
  no journal records. An address in the journal's `retired` list passes both checks.
- A unit's proof of its own CREATE role requires that the role's creation transaction created it and sent
  its declared constructor arguments, whatever its journal records.
- A deployed contract's code is the build artifact's, immutables aside, unless the unit overrides
  `_requireBuild` for a constructor-returned runtime and proves the code in its `check` step.

## What stays with the unit author

- Steps must be idempotent: a rerun sends nothing that the chain already has. The library cannot tell
  a step that repeats a send from one that does not.
- A declared role's `.ensure` must check the state that later transactions change.
- `Due` views must report whether the step still has work.
- Key custody, and the contents of `sprue.json` and `network.json`.

## Limits

- A step journals each role's intent and address before forge sends. If the broadcast fails partway,
  some journaled addresses have no code yet. Rerun the step; a pending intent is sent again only as
  the same transaction.
- A CREATE role is proven only with its creation transaction: the journal's `<role>Tx`, the unit's own
  broadcast records, or the chain, through an RPC that serves the deployer's nonce at past blocks. Where
  none shows it, the proof refuses, in a test too unless the test calls `trustTestCreations()`. A role that
  the same unit created in this run passes without one, since a simulation's deployment has no
  transaction; another unit proving it is refused.
- Chains in `chains.local` and `chains.test`, and a chain that `chains.unrecordedDeploys` lists, have no
  nonce fence. Losing a journal and its broadcast records there can deploy a role twice.
- A change of the pin is not supported. A CREATE role is proven only as the pin's CREATE, so after a
  new pin every role the old key created is refused, and `network.json` with `formerDeployers` is
  refused by name.
- A step's done check must stay done once it holds. sprue judges a done step before its date and does
  not wait for the date, so a check that holds before the date and fails after it reports the step
  done, and the step is never sent.
- sprue does not wait for finality. A reorg can undo a step the journal records. A step that
  reads the role through `_at` re-reads its code before it sends and refuses if the
  code is gone; a `.needs(...)` edge alone does not re-read it.
- An RPC node can lag behind the node that took the last send. The run then stops at the step that
  cannot see that send yet, with "has no code" or exit 5 and the plan unchanged; run again once the
  node catches up. forge's nonce check refuses a send simulated before the sender's own last
  transaction, but not one that repeats another account's change that the lagging node hides, which
  can fund the same target twice. Use an RPC with a consistent head (DESIGN.md).
- The run lock stops only accidental concurrent runs from one checkout, such as a second terminal or a
  forgotten background job, so that two runs do not interleave their writes to the journals and forge's
  `broadcast/` records. Another clone or worktree, another machine or a CI runner never sees it, and
  nothing on chain knows about it, so it gives no safety between runners. Between runners, only checks
  against the chain stop a duplicate send: forge refuses a send simulated before the same key's last
  transaction, on a live chain the nonce fence refuses to deploy a role again once another runner's
  CREATE by a known deployer has code, and a contract may refuse a second set-once value or a flag
  already set. A send computed from a read, such as a top-up amount from a balance, has no guard of its
  own when the runners send with different keys: both can send it. With one key, forge simulates and
  sends at the latest nonce, not the pending one, so the two runs' sends take the same nonces and one
  of each lands.
- A failing RPC stops the runner. A receipt that cannot be read while a step journals its deployment
  is left out of the journal, and the step goes on.

An external security audit is not part of this project.

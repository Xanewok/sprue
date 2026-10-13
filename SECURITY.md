# Security

Report a vulnerability privately through GitHub: the repository's Security tab, "Report a vulnerability"
(a security advisory). Do not open a public issue for it.

## What the guards check

The guards are code in `bin/sprue.mjs` and `src/`; [DESIGN.md](DESIGN.md#invariants) names the test or
end-to-end scenario for each invariant.

- `run` executes only a command line in the grammar that `plan` prints, as one `forge script` with no
  shell. A variable it names is one argument, whatever it holds, and an unset one is refused.
- An attended send needs `yes` typed at the terminal. It refuses if, from before the dry run to the
  answer, the sender's nonce on any chain of the network, git HEAD, the lines of
  `git status --porcelain`, `.env` or `~/.foundry/foundry.toml` changed. The status leaves out the
  network's `<unit>.json` and `*.metadata.json` files, which the run writes, so a new file there is
  not seen; a status line names a path and its state, not its contents, so an edit to a file already
  modified or untracked is not seen either. A clean checkout at the start keeps that list short;
  `--allow-dirty` waives it, and is refused when any chain of the network is live.
- A deploy step on a network that pins `deployer` sends only with that key, unless the run opts out
  with `--unsafe-unexpected-deployer`.
- A role the journal lacks is deployed only if no broadcast record of the chain holds a CREATE of its
  contract that landed or may land. On a live chain without a `chains.unrecordedDeploys` entry, it,
  or a role whose recorded deployment can no longer land, is also refused while a known deployer (the
  sender, the pin, any journal's deployer) has used more than 256 nonces, or has a CREATE with code
  no journal records. An address in the journal's `retired` list passes both checks.
- A deployed contract's code is the build artifact's, immutables aside, unless the unit overrides
  `_requireBuild` for a constructor-returned runtime and proves the code in its `check` step.

## What stays with the unit author

- Steps must be idempotent: a rerun sends nothing that the chain already has. The library cannot tell
  a step that repeats a send from one that does not.
- `_authenticate` must check the constructor arguments and state of a contract the journal reuses. The
  library checks its code, not its state.
- `Due` views must report whether the step still has work.
- Key custody, and the contents of `sprue.json` and `network.json`.

An external security audit is not part of this project.

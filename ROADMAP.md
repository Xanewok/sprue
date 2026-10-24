# Roadmap

What we plan or have researched, and why. Nothing here is a promise: 0.x releases may change the
API. Each item names its state: **planned** (designed, not built), **spiked** (a working
prototype exists) or **researched** (the problem is understood, the design is not).

## Next

- **A journal per unit and chain** (planned). A unit has one journal per network today, and a
  two-chain unit records `l1Block` and `l2Block` in it. A graph that deploys to several chains
  needs each chain's facts on their own, and every step would name its chain, so no default
  chain remains for a reader to resolve.
- **Done checked against the chain** (planned): a certificate verified on each role's own chain at plan
  time; it needs the per-chain journals above, because a two-chain unit certifies roles on chains the
  plan's fork cannot read.
- **One placement function** (planned) with three modes: CREATE; CREATE2 through a factory; and
  import of an existing address, with a committed code hash and an authentication predicate.
  CREATE2 is a separate opt-in path today, and a contract deployed outside the graph cannot be
  adopted. A CREATE2 intent (factory, salt, initcode hash) would be journaled before its first
  send, as a CREATE intent is.
- **The nonce fence from a start nonce** (planned), per chain and deploy key. Its refusal would
  name each unrecorded address and the unit build it matches. Today a chain whose earlier deploys
  no journal records is exempt as a whole (`chains.unrecordedDeploys`); a start nonce keeps the
  fence on for every deploy after it.
- **Done without a certificate** (planned). A step without a `<fn>Due` function is done only once
  its unit's `check` certified it, which ties the step to that one certificate.
- **A versioned journal format** (planned). Journals and certificates carry a schema version, and the
  changelog says what each release does to committed journals. A team keeps its journals for
  years, so an upgrade must never orphan them silently.
- **The plan as a structured file** (planned). The runner reads commands from forge's output lines today,
  so it must reject any line outside the command grammar. A plan file written by the graph script
  would remove that channel.

## Researched

- **Multisig and timelock senders.** A step sent by a Safe or a timelock would print a Safe
  transaction or a timelock batch instead of a command, and a rehearsal would impersonate the
  sender. A protocol's owner is rarely a single key.
- **Done, ours or theirs.** A permissionless step can be done by anyone. Planning would tell the
  three outcomes apart, and show the transaction that did it.
- **A graph that varies by chain or input.** Some deployments add or drop nodes per chain, such as
  a bridge only on the L2s. Whether the graph may vary must be settled before the per-chain
  journal layout is fixed.
- **Initcode pinned per role.** Each role would name its full artifact (`path:Contract`) and pin
  its initcode hash, so a rebuild that changes the bytecode is caught before a send.
- **Release binaries** (`bun build --compile` or a Node single-executable application) and an
  installer like `foundryup`, with checksums checked before anything runs.
- **Recovery from the chain alone.** Recovery reads forge's broadcast records today. Without
  them, it would need a log or trace search, and so an archive RPC.
- **Contracts a factory created,** found from the factory's nonce, its events or traces.
- **Concurrent runs** on one network: whether two runs need a lock.
- **What an attended run's approval covers.** The run stops if the state it compares
  ([SECURITY.md](SECURITY.md)) changes while it asks. Forge reads other state that a send could see
  differently from the dry run the person approved.
- **Chain values copied into calldata.** A step that reads chain state and sends it in calldata
  can race a change between the read and the send; a rule for such steps and a trace check.
- **Source verification** (Etherscan, Sourcify) from the metadata the journal records, as a
  step that sends nothing to the chain.
- **Checks scoped to the target.** An attended run checks every endpoint and the sender's pending
  transactions on every chain of the network; the target's closure and declared reads would do.
- **A plan exit code for CI**, so a job can fail when a network has steps left to send.
- **More than one instance of an artifact**, each with its own role identity. Today two roles that
  share an artifact and a sender make recovery from the broadcast records ambiguous.
- **CI on macOS and a consumer install** from `npm pack` and `forge install`, running an example.

## Known gaps

Behavior we have found and do not yet refuse or fix.

- **A reverted transaction may be sent again.** A rerun can send a transaction the chain reverted. It
  costs the gas of one reverted transaction per rerun, and forge exits 1. A possible fix compares
  forge's `evm_version` with a hardfork declared per chain in `sprue.json`.
- **The send runs forge again after the answer.** An attended run compares state around the question,
  but a file that changed between the question and the send is not refused. The
  one-run-per-network lock removes the realistic cause; the full fix is the open item
  "Bind the approval to the previewed transactions" in [DESIGN.md](DESIGN.md#open).

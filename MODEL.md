# The model behind sprue

Status: the model that sprue's design follows. Where sprue does not do something yet, the text says
"(target)". [DESIGN.md](DESIGN.md) holds the decisions; this file holds the reasons they take the shape they
do.

## Why it has this shape

- **Why does each send say how it is done (target)?** Its done check decides whether a rerun sends again,
  and what happens after someone else changes the chain. Without one, a tool either re-sends (and pays a
  premint twice) or never re-sends (and misses a changed fee).
- **Why is the chain, not a file, the record of done?** The chain is a store that other people change. A
  recorded "done" stays true only for a check that cannot turn false.
- **Why is the graph fixed before anything is sent?** So that a person can read the whole plan first.

## 1. What makes a rerun safe: stable done checks

A step is safe to run again when two things hold:

1. once its done check holds, the step sends nothing;
2. the done check is **stable**: once true, it stays true under every change that other people may make
   to the chain. This is a stable property in the sense of Chandy and Lamport ("Distributed snapshots",
   1985).

A stable check can be trusted from any earlier read. An unstable one must be read again at the chain's head
before each decision, and it needs a policy for when it turns false. Stability is not idempotence
(`x := x + 1` grows and is not idempotent), and it gives no order: two CREATEs by one key swap addresses
if their order changes, and a contract may require one bind before another. Order comes from `needs`.

So each send has a done check plus a few independent properties (target):

- what happens when the check turns false: refuse, apply again, or nothing because the step is retired;
- which transitions it may make, such as only from zero to the wanted value;
- when it retires: after a phase (a launch, a settlement), the step is done whatever the chain holds;
- what value it may move: which asset, from whom, to whom, how much;
- its execution state: due, pending, prepared for another sender, done, or failed.

The familiar kinds are presets of these properties:

| Preset | Done check | Stable? | When it turns false | Example |
|---|---|---|---|---|
| Create | the role is proven at its address | yes, once landed | cannot | deploy a vault |
| Edge | a flag the contract keeps | yes, while the contract keeps it | cannot | premint, seed, launch |
| Set once | the wanted value; unset is due; another value is a conflict | yes, if the contract forbids a change | refused | bind a vault to its source |
| Guarded replace | the wanted value; the contract allows a change, the tool refuses one | no | refused | rebinding before a launch |
| Level | the live value equals the input | no | applied again, with `change X -> Y` in the plan (target) | a fee, a curve |
| Top-up | the balance is at or above the target | no | sends the shortfall, until it retires | a faucet; funding until launch |
| Drain | the surplus is zero | no | sends the surplus | a sweep after a launch |
| Progress | the contract says complete; each send must advance it | yes at the end | cannot | a bounded walk |
| Pending edge | a fact on another chain | yes, once observed | cannot; pending between send and fact | a cross-chain notice |

A time gate is a guard, not a send: `block.timestamp >= t` stays true along one chain; a contract's own
view stays true only if the contract keeps it so. Exactly-once needs the effect and its marker to change in
one transaction, so a contract flag is the preferred done check for an edge. A record of the transaction
(a journal) gives at most once, and only while the journal survives. An edge's key comes from the inputs,
never from the block it is sent in, so a rerun finds the same effect.

A person's approval is a chain policy (a public chain asks for a typed `yes`), not a property of a kind.

## 2. What a record may cache

A record of a stable check may be cached. A record of an unstable check is sound only if it also records
everything the check read and the tool validates each of those reads again, which is the same as running
the check again.

In "Build Systems à la Carte" (Mokhov, Mitchell, Peyton Jones, 2018) terms, a recorded "this was checked
with these inputs" is a verifying trace. It is sound when it records and validates every dependency. A
`check` reads the live chain, and its record holds the facts it certifies and the hash of its input file,
not every chain read, so it cannot be validated cheaply. So the journal caches identity, which is stable
once landed, and does not cache "done": done is the step's own check, read at the chain's head. Today's
exception is the unit's certificate: it marks done a `check` step, the `.doneByCheck()` steps that the
`check` reaches, and every step of a unit that cannot be probed, until the unit's input changes (DESIGN.md
decision 6). The model's target drops it, or keeps a record only of stable checks.

The same paper separates applicative dependencies, known before anything runs, from monadic ones,
discovered while running. A step's `needs` are applicative, so `plan` can print every node and its order
before the first send. This holds only if `needs` cover every dependency a step body uses. The number,
targets and data of a step's transactions can still depend on what it reads.

## 3. Modes as handlers of one step

A step body is written once and each mode of sprue interprets it differently. This is the design of
effect handlers (Koka, Eff, OCaml 5) used as an analogy: Solidity calls are not algebraic effects, and a
mode that prints or prepares a send must still give later code the values it needs.

| Mode | What it does with a step's sends |
|---|---|
| probe | simulates up to its first `_startBroadcast()` or journal write, and reports due |
| plan | prints |
| run | broadcasts |
| prepared (target) | writes the sends for another sender, such as a Safe, and reports pending |
| test fixture (target) | pranks the senders and warps the dates |
| replay (target) | simulates the whole step, then checks that its done check holds and a second run sends nothing |

The replay is the strongest check that needs no declaration: it catches a wrong done check before the send.
A value check needs the whole simulation too (target): record the state changes of the step's sends and
compare them with the step's declared value budget. Logs are not enough evidence: an ERC-721 transfer has
the ERC-20 `Transfer` signature, a contract can emit any log, and an allowance or an accounting credit can
change with no log. The protocol's own assertions stay the authority.

## 4. A fixed declarative layer and an escape hatch

`steps()` is Solidity, but its result is a finite graph, fixed before any send: steps, their `needs`,
senders, gates, chains and (target) done properties. This is staging, like Bazel's split between loading the
build graph and executing it. The step body, in Solidity, is the escape hatch for anything the
declarations cannot say.

The common case is a declaration that gets its plan line, its order and (target) its value check and its
tests for free: one generated property per preset, such as "a drained top-up is due again until it
retires" or "a conflicting bind is refused". A generated test proves the declaration is honoured, not that
the author chose the right one. A declaration is worth adding only for what it derives: in Solidity a
declaration costs about as many lines as the code it replaces.

## 5. Prior art

- Kubernetes controllers are level-triggered; finalizers coordinate cleanup before deletion.
- Terraform's `ignore_changes` stops selected drift from being reconciled, and `prevent_destroy` blocks
  destruction.
- Ansible's `creates:` skips a command when a file exists, a done check by fact; `changed_when` changes
  only what the task reports.
- In durable execution (Temporal and similar), an activity may run more than once; exactly-once comes from
  an idempotent receiver.
- On chain: Hardhat Ignition records each call in a journal, does not send it again, and refuses a
  completed step whose arguments changed. Sphinx takes done from the chain (executed Merkle leaves).
  hardhat-deploy skips a recorded deployment, in some paths without a chain read; rocketh adds an optional
  guard for calls. None of the tools we read declares how each send is done.

## 6. Cases still open

- **Recurring actions,** such as funding each epoch. An edge keyed by the period fits, but sprue has no
  scheduler (DESIGN decision 18): a finite set of periods is planned, or the action stays outside sprue.
- **Timelocks.** OpenZeppelin's `TimelockController` moves an operation from unset to pending to ready to
  done, and a cancel returns it to unset. Schedule and execute are two edges with a time gate between them;
  the operation's key must include the wanted calls, and a cancel makes the schedule due again.
- **Composite transactions,** such as a launch that approves, seeds and locks liquidity in one call. They
  stay one step: splitting them changes what a failure leaves behind.
- **Mixed steps.** One step may hold sends of different presets, so the properties belong to each send,
  not to the step.
- **Removal:** revoking one role needs a read of that membership; stating the exact set needs enumeration.
  Renouncing is permanent only if the contract has no other admin or upgrade path.
- **Emergency runbooks,** such as pause and unpause: level setters that must bypass the drift policy, by a
  named escape hatch.

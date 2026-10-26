# The model behind sprue

Status: the model that sprue's design follows. Where sprue does not do something yet, the text says
"target". [DESIGN.md](DESIGN.md) holds the decisions; this file holds the reasons they take the shape they
do.

## Why it has this shape

- **Why does each send say what kind of effect it is (target)?** The kind decides when the send is done, what a
  rerun does after someone else changed the chain, and whether its order can be derived. Without a kind, a
  tool must either re-send (and pay a premint twice) or never re-send (and miss a changed fee).
- **Why is the chain, not a file, the record of done?** The chain is a store that other people change. A
  recorded "done" stays true only for facts that cannot become false.
- **Why is the graph static?** So that a person can read the whole plan before anything is sent.

## 1. Trigger kinds are monotonicity classes

The CALM theorem (Hellerstein and Alvaro, "Keeping CALM", CACM 2020): a program whose facts only grow gives the same result
in any order and after any number of reruns, with no coordination. A program that can retract a fact needs
coordination. Each kind of send is a small lattice:

| Kind | Lattice | Monotone | Done means | After an outside change | Example |
|---|---|---|---|---|---|
| Create (CREATE, CREATE2) | written once, by identity: the address commits to it | yes | the role is proven at its address | nothing to do | deploy a vault |
| Time gate | the clock, `false < true` | yes | the time or the contract's own view is reached | stays done | sale opens at a date |
| Edge (exactly once) | a flag, `false < true` | yes, while the contract keeps the flag | a durable fact: the contract's flag, or (target) a record tied to a transaction | stays done, sends nothing | premint, seed, launch |
| Set once (bind) | `unset < v`; another value is a conflict | yes | the value is unset or the wanted one | refused, never re-pointed | bind a vault to its source |
| Level (setter) | last writer wins | no | the live value equals the input now | due again; the plan prints `change X -> Y` (target) | a fee, a curve |
| Top-up | a balance that others can drain | no | the balance is at the target | due again; sends the shortfall | a test faucet |

The rule that follows comes from the theory, not from taste:

- Monotone nodes may be re-run freely, and their order may be derived.
- Non-monotone nodes need an explicit order, a printed diff and a person's approval.

Exactly-once is a property of state, not of a script. It lives in one of two places: a contract's monotone
state (a flag, a renounced owner, an executed Merkle leaf) or a record of the transaction that made it
(a journal). Only the first survives a lost journal, so a contract flag is the preferred done rule for an
edge. An edge's key comes from the inputs, never from the block, so a rerun finds the same effect.

## 2. What a record may cache

A cache of a fact is sound only when the fact is monotone: a monotone fact cannot become false later. A
cached non-monotone predicate is the thing that goes stale.

"Build Systems à la Carte" (Mokhov, Mitchell, Peyton Jones, 2018) says the same in build terms. A recorded
"this was checked with these inputs" is a verifying trace. A verifying trace stays valid only while nobody
else changes the store, and the chain is a store that others change. So the journal caches identity, which
is written once, and does not cache "done": done is the step's own check, read at the chain's head. The
exception is a `.doneByCheck()` step, which its unit's certificate marks done until the unit's input changes.

The same paper separates applicative dependencies, known before anything runs, from monadic ones,
discovered while running. A step's `needs` are applicative, so `plan` can print every node and its order
before the first send. A step body may branch on what it reads; the graph may not.

## 3. Modes are effect handlers

In languages with algebraic effects (Koka, Eff, OCaml 5), a program requests effects and a handler decides
what each request does. A step body requests a small set: create, call with a kind (target), read, wait until. Each
mode of sprue is a handler of the same body:

| Handler | What it does with a step's effects |
|---|---|
| probe | simulates, collects, sends nothing |
| plan | prints |
| run | broadcasts |
| prepared (target) | writes the sends for another sender, such as a Safe, and stops |
| test fixture (target) | pranks the senders and warps the dates |
| replay (target) | runs the step again on its simulated result and refuses if it would send again |

That is why one step can be a deployment, a runbook and a test fixture. Solidity cannot check effects
statically, so the probe checks them at run time (target): it records each send's logs and value, and
refuses a send that moves ETH or emits an ERC-20 `Transfer` unless its kind allows it. A mint or deposit
that emits neither still relies on its author.

## 4. A small declarative layer and an escape hatch

The declarations are finite and static: roles, kinds (target), gates, `needs` edges and senders. They are not a
programming language. The step body, in Solidity, is the escape hatch for anything they cannot say. This
follows Bazel's Starlark (no recursion, no unbounded loops) with `genrule` as its escape, and total
configuration languages such as Dhall and CUE.

The common case is a declaration that gets its plan line, its effect check (target), its order and its tests for
free (target: one generated property per kind). A declaration is worth adding only for what it derives:
in Solidity a declaration costs about as many lines as the code it replaces.

## 5. Prior art

- Kubernetes controllers are level-triggered by design and use status conditions and finalizers for edges.
- Terraform keeps drift in check per resource with `lifecycle { ignore_changes, prevent_destroy }`.
- Ansible's `creates:` makes a command edge-triggered on a fact, and `changed_when` is a custom done rule.
- Durable execution (Temporal and similar) gives exactly-once activities through idempotency keys, and
  durable timers.
- CFEngine's promise theory is built on convergent operators.
- On chain: Hardhat Ignition records each call in a journal and never sends it again, without reading the
  chain, and refuses a completed step whose arguments changed. Sphinx takes done from the chain (executed
  Merkle leaves). hardhat-deploy skips a recorded deployment without a chain read; its successor adds an
  optional guard for calls (rocketh). None of them types its effects.

## 6. Cases the kinds do not cover yet

- **Recurring actions,** such as funding each epoch or posting a root per period. A periodic gate is not
  monotone. It needs a kind keyed by the period: set once per epoch.
- **Timelocks.** OpenZeppelin's `TimelockController` exposes a monotone state machine (unset, pending,
  ready, done). Schedule and execute are two edges with a time gate between them.
- **Cross-chain sends:** an edge whose completion is a fact on another chain, with a pending state between.
- **Removal:** revoking a role needs enumeration to state exact membership; renouncing is an irreversible
  edge.
- **Emergency runbooks,** such as pause and unpause: level setters that must bypass the drift policy, by a
  named escape hatch.

# Authoring DX: less unit code, same guarantees

Status: exploration on `explore/authoring-dx`. Nothing here is released. Each primitive lands on this branch
as its own draft pull request, and an adopting project measures what it cuts before any of it moves to `main`.

## Goal and rules

Cut the code a unit author writes, in steps of about a quarter, by moving guarantees from the unit into
sprue. A primitive counts by the unit lines it deletes and the class of mistake it removes.

- Safe by default, with an explicit opt-in for the manual form (as `unsafe` in Rust).
- Small declarative primitives that compose, with an imperative escape hatch (as `useRef` in React).
- Foundry's own mechanisms before new sprue concepts.
- Compile-time checks stay: the typed `this.fn` selectors.

## A: a step is its own `Due` view (built)

A step with no `Due` view is judged by running it in a probe. Today such a step is written twice: the step,
which decides and sends, and a `<fn>Due` view, which repeats the decision.

```solidity
s[1] = _step("vault.fund", this.fund).needs("vault.deploy").notBefore("vault.openAt");
```

How it works:

- The graph calls `IProbe(unit).probe(stepCalldata, sender)`. `probe` sets a flag and calls the step on
  the unit itself under `vm.startPrank(sender, sender)`, then reverts with `Probed(returned, result)`, so
  no EVM state the step changed remains. The sender is the step's `.by`, or the plan's own.
- In a probe, `_startBroadcast()`, `_put` and `_certify` (when the certificate would change) revert with
  `StepDue()`. The step is due at its first send or journal write, done if it returns, and waits with its
  own revert reason otherwise, as a `Due` view's revert does today.
- `_deployRole` decides a reused role with the `_reuseForDue` rule before it opens a broadcast: a probe
  has no broadcaster.
- `.due(this.fnDue)` stays as the explicit form. `.doneByCheck()` is the opt-in to the certificate.

Hazards found, and what answers each:

| Hazard | Evidence | Answer |
|---|---|---|
| forge keeps the transactions of a reverted call in the dry run, and `--resume` sends a saved dry run | forge 1.8.5: a call that broadcast `set` and a CREATE, then reverted, left both in `dry-run/run-latest.json` | No broadcast may start in a probe: `_startBroadcast` reverts first, and the prank makes forge refuse `vm.startBroadcast` and `vm.broadcast` ("you have an active prank") |
| A step that calls `vm.startBroadcast` directly returns normally and reads as done | same probe without the prank: `# done toy.raw` | The prank refuses it, and the plan waits with the fix; `Probe.t.sol` |
| `_deployRole` opens the broadcast before it decides, so every deploy step would read as due | `_deployRole` calls `_broadcaster()` first | `_reuseInProbe`; mutant without it fails `test_plan_judgesDeployRoleByItsReuse` |
| A step that opens the broadcast before it decides is due forever | design | `run` stops at exit 5 when its plan repeats: loud, never a false done. Decide first, or keep a `Due` view |
| A step whose remaining work is a journal write reads as done | `_writing()` is false in a plan's dry run | In a probe `_writing()` is true and `_put` and `_certify` refuse the write; mutant fails `test_plan_countsAJournalWriteAsWork_andWritesNothing` |
| A receipt is in forge's record only after the run, so counting it as work plans every deploy twice and `run` stops on a repeated plan | e2e `scenario_rerun` failed before `_recordReceipt` skipped probes | `_recordReceipt` does nothing in a probe; the next run or `check` journals it |
| Without its `Due` view, a step that a `check` follows became certified: printed before its needs landed, and done after the certificate whatever the chain says | e2e `scenario_lag` sent `vault.fund` before the lagging node showed the vault | In a unit that answers the probe, a `check` certifies only itself and `.doneByCheck()` steps; `test_check_certifiesOnlyTheStepsNoProbeJudges` |
| `_adopt` refuses a plan whose environment moves forge's records, so a probe turned the runner's config refusal (exit 2) into a step refusal (exit 3) | e2e `scenario_failure` | A probe skips that check: it queues nothing, and the runner checks the step's own command |
| A step's own `console.log` lines print during `plan` | design | `_done` is silent in a probe; a unit's own logs are its author's |
| A step catching its own `StepDue` revert would read as done | design | Not guarded: a step must not catch a revert of its own sends |
| The probe ran as the plan's sender, so a step whose work depends on its `.by` sender read as done | cross-family review: a forge dry run of the declared sender sent | `probe(step, sender)` pranks as the step's sender; `test_plan_probesAsTheStepsSender` |
| `_recordBuild` wrote the metadata file before its `_put` refused | review | It refuses first; `test_plan_countsABuildRecordAsWork_andWritesNoMetadata` |
| Asking a unit whether it answers the probe ran a test double's fallback | review: its `Due` view changed by registration | A static call of `probes()`; `test_add_asksAUnitWhetherItProbesWithoutRunningIt` |
| A step that reads `<role>Tx` to decide sees no receipt in a probe | review | Documented: a decision must not read receipt keys. Counting the receipt as work brings back the repeated plan |
| `vm.warp`, fork selection, serialized objects and direct file writes survive a probe | review | Documented, as for a `Due` view |

A unit that does not answer the probe, such as a test double, keeps every rule it had: `Due` views and
certificates, and `MissingDoneRule` for a step with neither.

## Verdicts on the next primitives

Order: E, then B with C, then D. Each is independent of A's internals and can be adopted alone.

- **E. Prove creation against the journal's own record** (take, changed). Proving against this build's
  initcode orphans a role after any later source edit. Prove instead that the chain's creation input hashes
  to the journal's `<role>InitcodeHash` and ends with the arguments the step expects. The chain then fixes
  the arguments, and the code rests on the build the journal recorded (`<role>CodeHash`, the metadata).
  Keep today's call as the stricter form. This deletes only the parts of a unit's `authenticate` that
  re-read constructor arguments; state that later transactions change still needs a check. It needs a
  cross-family review before it lands, since it moves trust for the code from the build to the journal.
- **B. The send block** (take, folded into C). `_startBroadcast()` becomes idempotent within a step and
  `_done()` without an argument closes an open broadcast and reports whether one opened. With A, the flag
  only labels the log, so B's value is the deleted lines, not safety. No new name: keep `_startBroadcast`.
- **C. Declared wants** (take). `_want(bool holds, address target, bytes call)` sends `call` when `holds`
  is false, with `abi.encodeCall` keeping the typed selector. Under A it needs no `Due` logic: the first
  unmet want reaches `_startBroadcast` and the probe reads the step as due. Wants run in order, and a step
  whose later condition depends on an earlier send keeps imperative code.
- **D. Certificates declared once** (take the builder, defer the edges). A certificate builder that records
  the receipt and prints the certificate deletes the hand-written logs and serialize calls. A typed edge
  from a certificate key to a dependent's input, checked at graph build, changes how dependents read
  addresses; leave it as research until A to C are measured.
- **F. Typed inputs** (the adopter's, no sprue change). `vm.parseJsonType` or `abi.decode(vm.parseJson(...))`.
- **Steps chained in declaration order by default** (reject). An implicit `needs` hides edges, and moving a
  line would reorder CREATEs and change fresh-chain addresses.

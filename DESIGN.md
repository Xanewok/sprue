# Design

What sprue assumes, what it guarantees, and the decisions behind it. [GUIDE.md](GUIDE.md) says how to use it; the
[ROADMAP](ROADMAP.md) says what is planned. Decision numbers are stable: cite them, never renumber.
[MODEL.md](MODEL.md) holds the model these decisions follow.

## Why it has this shape

- **Why is the journal written before the send?** `forge script` runs the whole script, journal writes
  included, and only then broadcasts. A journal that names the intent (deployer, nonce, initcode hash)
  before the transaction exists lets a rerun tell a lost send from a pending one.
- **Why is "done" read from the chain and never recorded?** A record of done goes stale when a bind or a
  setting changes after it, and nothing re-reads what the record stood for. A step is done by its probe or
  its `Due` view, read at the chain's head, and the journal caches only what is stable once landed.
- **Why does `plan` print commands instead of the tool sending in-process?** Each step has its own sender,
  its own forks and its own dry run. A separate `forge script` per step is the unit the person approves, and
  the graph's `rehearse` only simulates for the same reason. Every line is a plain command a person can paste.
- **Why does an attended run compare state around the question?** After `yes`, forge runs the command again.
  The run refuses if what it compares ([SECURITY.md](SECURITY.md)) changed, because that would make the
  second run differ from the dry run the person read.
- **Why does a rerun send nothing?** The graph plans again and skips every step its done rule calls done,
  so an interrupted run is finished by running it again; a step's own idempotence is the unit author's.
- **Why does `run` stop at a future date instead of waiting?** A person at a terminal should not hold a
  process open for days. Exit 4 means "come back"; `--wait` opts in. Only on Anvil does `run` move the clock.
- **Why does every `sprue rehearse` start over?** State kept between rehearsals would need rules for when it
  stops being true: a restarted fork, an edited input, a step that failed halfway. A fresh copy on fresh forks
  needs none. The cost is replaying the steps the network still lacks.
- **Why string ids and a derived order?** A numbered script list states a total order that is false and
  changes when a unit is inserted. Units declare edges; the graph orders them.

## Assumptions

What sprue relies on and cannot check.

- Foundry runs a script to the end before broadcasting, and `broadcast/` records are complete and unedited.
  Recovery and receipts read them as evidence; a lost record plus a lost journal is not recoverable (ROADMAP).
- `rpcJson` exists (forge 1.8 or later). An RPC reports a consistent head; fork creation tries a lagging
  node five times, a second apart.
- The repository is trusted: units are Solidity that `forge script` executes with the `fs_permissions` the
  project grants.
- One operator and one key per journal, until a pending transaction resolves. The nonce fence reads the
  CREATE addresses of the sender, the pin and every journal's deployers, up to 256 nonces each; it does not
  see a CREATE2 deployment, a CREATE of any other key, or a transaction another key still has pending.
- The unit author keeps steps idempotent, makes a role's `.ensure` check the state of a reused contract
  (the library proves its identity, code and recorded constructor arguments), and makes `Due` views report
  real remaining work (SECURITY.md).
- The terminal check guards against an accident, not an agent: a keystore password file decrypts without a
  person. No agent or CI should hold a key for a public chain.
- `sprue.json` and `network.json` are the project's to get right; sprue validates their shape, not their meaning.

## Invariants

Each is checked by the named test or end-to-end scenario (`test/`, `test/e2e/e2e.sh`).

| Invariant | Evidence |
|---|---|
| A role is deployed only if its journal lacks it or its recorded deployment can no longer land; a pending intent is resent only as the same transaction. | `CoreUnit.t.sol` `test_deploy_aPendingIntent_isSentAgainOnlyAsTheSameTransaction`; e2e `scenario_kill` |
| The intent is journaled before the address; a simulation outside a rehearsal network journals nothing. | `test_deploy_journalsTheIntentBeforeTheAddress_andTheHookRunsOnlyForANewDeployment`, `test_deploy_aSimulationJournalsNothing` |
| A rerun of a finished target changes no block, nonce or journal bytes. | e2e `scenario_rerun`; `test_check_rerunAtALaterBlock_leavesTheJournalByteForByte` |
| The fence refuses when a CREATE of a known deployer has code no journal accounts for, and never on an unfenced chain. | `FenceModel.t.sol` `testFuzz_fence_*` |
| A deployed contract has the artifact's code, immutables aside, unless the unit overrides `_requireBuild`; a reused one has the journal's code hash, or the code that exactly the journaled initcode left where it landed (a CREATE2 address, or a CREATE's creation transaction, shows that initcode). | `test_deploy_refusesACreateThatIsNotTheArtifactAndRecordsNothing`, `test_deploy_aRoleThatLandedWithOtherCodeThanItsSimulation_isProvenByItsCreationInput`; `Create2Code.t.sol` |
| A declared role is returned only when its address follows from the identity its journal records (deployer and nonce, or factory, salt and initcode hash), its code hash (as in the row above) and recorded arguments are the journal's and the declared ones, a CREATE's known creation transaction created it and sent the declared arguments, and its `.ensure` passes; another unit's role, by its identity and code. | `Roles.t.sol` `test_at_*`, `test_create2_*`, `test_extern_*`, `test_check_runsOnEveryReuse_andItsRefusalStopsTheStep` |
| Where `network.json` pins a deployer, a declared CREATE role was created by the pin, and only the pin sends one, whatever the opt-in to another key. A CREATE2 role is proven whoever sent it. | `Roles.t.sol` `test_deploy_onAPinnedNetwork_refusesAnotherKey_evenWithTheOptIn`, `test_at_refusesARecordedDeployerOtherThanThePin`, `test_pin_aNetworkThatListsFormerDeployers_isRefusedByName`, `test_create2_isProvenWhoeverSentIt`; e2e `scenario_failure` |
| `recover` journals only one unambiguous, current deployment and writes nothing before every check passes. | `CoreUnit.t.sol` `test_recover_refuses*`, `test_recover_ofACompleteJournal_sendsAndWritesNothing`; e2e `scenario_recover` |
| Node order is the lowest ready node by unit, then declaration; a cycle is refused with its ids. | `GraphOrder.t.sol` `testFuzz_order_*`, `testFuzz_cycleNamesARealLoop` |
| Every step has a done rule. A `check` is judged live: once what it asserts changed, it is not done. | `StepBuilders.t.sol` `test_aStepWithoutADoneRuleIsRefused`; `Probe.t.sol` `test_plan_judgesACheckLive_andRefusesOnceWhatItAssertsChanged`; `Roles.t.sol` `test_endCheck_*` |
| A probe sends nothing, writes no journal or build record, and keeps no EVM state; a step is due at its first send or write, and a direct broadcast is refused. | `Probe.t.sol` `test_plan_*` |
| A production node never depends on a test-only node. | `StepBuilders.t.sol` `test_productionNeverNeedsATestNode` |
| A malformed pin is refused before any send; under a pin, another key sends a CREATE2 role only with the opt-in, and a rerun that sends nothing passes with any sender. | `CoreUnit.t.sol` `test_pin_*`; `Create2Code.t.sol` `test_deployRoleCreate2_refusesAnotherDeployerThanThePin_beforeTheFactoryCall`, `test_deployRoleCreate2_anotherDeployerThanThePin_sendsWithTheOptIn` |
| An input date on a step off the default chain is refused. | `FileGraphChains.t.sol` `test_plan_refusesAnInputDateOnAChainOtherThanTheDefault` |
| Every fork a step selects serves the chain id `network.json` names. | `CoreChains.t.sol`; e2e `scenario_refuses` |
| `run` executes only lines in the plan grammar; a `sprue.json` path holds only `A-Z a-z 0-9 _ . / -`. | e2e `scenario_grammar` (`plan-grammar.sh`); `CoreChains.t.sol` `test_project_isRefusedUnlessItIsExactlyTheShape` |
| A send builds into `out/`, as `forge config` resolves it. | e2e `scenario_failure` |
| A send writes its records where its units read them, as `forge config` resolves it; a rehearsal network's records and resume data, a dry run's too, are only under its own directory, never in `broadcast/` or `cache/`. | e2e `scenario_attended`, `scenario_failure`, `scenario_grammar` |
| `sprue rehearse` sends only to forks it started, as impersonated senders: the real chains mine nothing and the network's own files are unchanged; a signer flag, a keystore that `.env` names, or an `eth_rpc_url` that forge resolves is refused; its forks stop at the end, on Ctrl-C, or with `--keep` at the next `rehearse` of the network or `--stop`; it refuses an existing directory without its `.sprue/`. | e2e `scenario_rehearse`, `scenario_two_chain` |
| An attended send needs a typed `yes`, stops on a change during the question, and asks for every step. | e2e `scenario_attended` |
| One run of a network runs at a time, a rehearse of its copy and a plan of a copy included: a second refuses while the first, or a forge the first started, runs; a signal to the runner stops its forge before the lock is released. | e2e `scenario_concurrent` |
| Exit 4 before a date; `--wait` waits; Anvil's clock is set for a date, and a second chain's clock for its own dates. | e2e `scenario_wait`, `scenario_two_chain` |

## Decisions

1. **Solidity owns the graph and every step.** There is no recipe format. The runner only consumes the
   plan Solidity prints. Every printed command is a plain `forge script`, so a person can run the path with
   Foundry alone and keep every check the Solidity makes (journal, fence, pin, code); the runner (Node, `cast`)
   adds the replanning loop and the attended checks. Rejected: a declarative recipe
   (Cannon, Terraform style), which adds a second language and hides the pause between dry run and send.
2. **Plan is a dry run, apply is the same command with `--broadcast`.** Plain CREATE by default; CREATE2 is
   an opt-in a unit takes through `_requireCreate2Address` and the keyless factory pinned by code hash.
3. **Recovery is an explicit `recover` step.** A unit with one rebuilds a lost journal from `broadcast/`
   records; no step adopts a deployment on its own. A refusal names the command only when a contract
   compiled from the unit's script has `recover(string)`. A stray CREATE2 landing is refused, not adopted.
4. **Journals are per unit and committed.** Addresses, intent, the code each contract must have, and the
   build metadata. Git is the history. Stamped with the chain id the step last selected.
5. **A deploy step converges.** `_deploy(role)` proves what it reuses, by the identity its journal records
   and the role's `.ensure`, and sends only a missing role;
   `_done` ends a step by printing what it sent, the files to commit and the next `plan` command;
   `_done()` reads what it sent from the broadcaster's nonce on the chain where it first opened its
   broadcast, so a step that sends on one chain cannot report it wrongly. The report only labels the log.
6. **Done has three forms, and a step needs one.** A probe: the step itself, run and reverted, is due at
   its first `_startBroadcast()` or journal write. A `<fn>Due` view (true while work remains). For a
   node with no step, a predicate (`until`) that anyone may satisfy. Construction refuses a step with
   none (`MissingDoneRule`). A `check` is an ordinary probed step: `_endCheck` makes it due only while a
   deployed role's receipt is unjournaled and findable in the unit's records or on the chain.
   The probe runs under a prank, because forge refuses its broadcast cheatcodes under one: forge keeps the
   transactions of a reverted call in the dry run, which `--resume` would send. It pranks as the step's
   sender, `.by` or the plan's own. A receipt still to journal is not work for a deploy step, since forge
   writes the record after the run; the unit's `check` journals it. A graph asks a unit whether it answers the probe with a static call, so asking runs
   nothing. Rejected: a certificate of a `check` that marks steps done (it hides drift after the
   certificate, and a changed bind stays done).
7. **`check` settles only deployment evidence.** It journals receipts and the `<role>CodeHash` and `<role>Commit` of what it proves, and nothing else; a rerun leaves the journal unchanged.
8. **A node is a gate, a view, or a predicate on chain state.** A time gate reads a contract's view where
   one exists (movable until reached); a date in an input is only a forecast. The step's own read-only check
   decides due or done; making the contract enforce the condition when the step runs is the unit author's
   job. A script reads during simulation and sends later, so its read is never a lock.
9. **No step needs historical state.** The library reads the current state of the fork it creates at the
   head, a transaction by hash, and its receipt. One fallback reads the past: with no broadcast record,
   a CREATE's transaction is found through the deployer's nonce at earlier blocks, which a full node
   keeps only for recent ones; past that, it finds none. Rejected: an archive RPC; recovery from the
   chain alone is ROADMAP.
10. **The graph's order derives from units.** Kahn's algorithm: of the ready nodes, the first-registered
    unit, then the first declared. A unit orders only its own nodes. A cycle, a duplicate id, an unresolved
    need, an unlisted unit and a selector that does not match the function name are refused at
    construction.
11. **Dependencies are string ids (tentative).** Typed references are preferred when the compiler allows
    them without a fight; ids stay forward compatible.
12. **A network may pin its deployer.** `network.json`'s `deployer`, which is then the default `DEPLOYER`
    of `run` and `rehearse`: a committed choice beats one inferred from the signer. A run that cannot sign
    as it refuses at the start, and a CREATE step sent by another key refuses before it sends, unless
    `--unsafe-unexpected-deployer` (`UNSAFE_UNEXPECTED_DEPLOYER=1`). One pin per network; a pin per chain
    waits for a network that needs one.
13. **Chains are a named map.** `network.json` keys chains by name with an id and an `rpc` alias from
    `foundry.toml`'s `[rpc_endpoints]`, the one RPC configuration, which forge and cast resolve; a file never
    holds a URL, which may carry a key, but for a rehearsal copy's loopback forks. Rejected: an `R` variable
    and `<CHAIN>_RPC` fallbacks beside the aliases (a second configuration that printed commands depended on). A chain's kind
    (`local`, `test`, `live`) derives from `sprue.json` by id and is never stored. `chains.default` names the
    chain of a step without `.on`; `chains.unrecordedDeploys` exempts a live chain from the fence, with a reason.
14. **Public chains run attended.** A run on a network with a chain not listed `local` needs a terminal, no
    `CI`, one signer flag, a clean tree (`--allow-dirty` waives it when no chain is live), and `yes` per step
    after showing the dry run's transactions and cost. A development node is refused outside a rehearsal
    network: a run on a fork would write the network's committed journals. `sprue rehearse` runs a target on
    forks (decision 20); the graph's `rehearse` simulates one on a staged `<rehearsal>-rehearse-<network>` copy.
15. **The executor never waits for a date by default.** It exits 4, or with `--wait` polls; on Anvil it sets
    the clock of the chain the date names.
16. **Test-only parts stay apart.** A test-only node is a target only on a test or local chain, and no
    production node may depend on one.
17. **The generic layer names no project file.** Project facts reach it through `sprue.json` and the graph
    script; its files import only forge-std and each other.
18. **No scheduler or keeper.** Time limits live in the contracts that need them, callable by anyone after
    their time. Operations that are not one-time deploys stay plain scripts.
19. **`plan` and `rehearse` judge in list order.** `plan` prints a target's closure, each node `# done`,
    `# not before`, `# cannot reach` or a command, and ends with `# then plan again <node>` where a node
    cannot be judged until a dependency lands (a predicate's date not yet reached, an input date not yet
    reached by a step that is not done, or a view or predicate whose dependency is not done). A done step has
    no date line: its done check must stay done after the date (SECURITY.md). A predicate holds only now, so
    it is judged only once its date is reached. `rehearse` simulates the closure in that order on a staged copy of the
    network, warping to each date (`FOUNDRY_BROADCAST=<d>/broadcast FOUNDRY_CACHE_PATH=<d>/cache forge script
    <graph> --sig 'rehearse(string,string)' <network> <target> --rpc-url <rpc> --sender <deployer>
    --disable-block-gas-limit`, where `<d>` is
    `<paths.rehearsal>-rehearse-<network>`); it refuses `--broadcast`, and stops at the first node whose sender is
    another account, since a forge run has one sender and a fork forgets the simulation. A predicate is
    judged after its dependencies and date, and stops the run when unmet.
20. **`sprue rehearse` starts over on forks it owns.** Each invocation stops the forks a `--keep` left, copies
    `deployments/<network>/`'s files into `<paths.rehearsal>-<network>`, starts one Anvil per `rpc` alias,
    names each fork's loopback URL as the copy's `rpc` for its chains, and runs `run`'s loop on the copy, unattended, with `--unlocked` and every
    sender impersonated. No key signs, so a fork that keeps a public chain id never holds a transaction the
    real chain would accept. Every step is judged on the fork, as on the real chain, so a `--block` before a
    deployment shows it as not done. It shows only what Anvil reproduces: no bridge delivery between forks, and no
    L2's own rules.

### Prior art

Surveyed 2026-10. No tool combined Solidity-only steps, plain CREATE, and gates on dates and chain facts.

| Tool | Borrowed or lacking |
|---|---|
| Foundry alone | `broadcast/` and `--resume` finish one run; no graph, no journal, a rerun resends every CREATE. |
| Hardhat Ignition | A module graph and an intent journal, refusing a rerun with other arguments in every state (copied for a pending CREATE). Node-based; after a successful deploy it does not compare the bytecode; no gates. |
| hardhat-deploy, rocketh | A file per deployment returned on rerun. TypeScript; redeploys on drift unless told to skip. |
| Cannon | Step packages with snapshots. TOML recipe; a public registry. |
| Sphinx, treb | Solidity declarations, Safe execution, same addresses on every chain. CREATE2 or CreateX deploys. |
| forge-deploy | Typed records from broadcasts. A separate Rust CLI. |
| Catapulta | Hosted deploy and verification. A Node CLI and a service. |
| Terraform | Plan and apply, `depends_on`, drift. Inverted authority: it trusts its state, sprue's steps trust the chain, and a lost journal makes a step refuse while records show the deployment. |

What none has: a calendar of operations that the chain gates, a code-hash check of every reused
contract against its recorded build, and a declaration of how each send is done. Sphinx and treb take
done from the chain; Ignition, hardhat-deploy and rocketh from a journal (hardhat-deploy reads the chain
for a deterministic deploy, rocketh for its optional guards); Cannon from a step hash, plus a code check
of a CREATE2 deploy. What sprue lacks against them: Safe export for post-handover steps
(ROADMAP) and the same addresses across chains. Confirmations: Ignition asks once for any chain but 31337;
Sphinx asks before a proposal; forge has no general confirmation for public networks.

## Open

Planned work is in [ROADMAP.md](ROADMAP.md).

- **Bind the approval to the previewed transactions.** The run compares state around the question and then
  reruns the command. Sending exactly the dry run's transactions (`forge script --resume` on its sequence, or
  `cast` per transaction) would change the "same command with `--broadcast`" contract.
- **Why journals carry `<role>Commit`.** They copy forge's commit and receipt facts. Open: reuse more of
  forge's records, or keep a vendor-neutral schema and adapters. Forge records `HEAD` without dirtiness, so
  an attended run journals `<role>Dirty: true` beside the `pending` commit when the dry run saw a change.

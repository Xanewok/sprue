# sprue map

A static HTML map of what a Foundry deployment created and how the contracts connect, built from
forge's own broadcast records. It works for any Foundry project; sprue's data, where present, only
adds names and verified links. The command is `sprue map`.

## Why it has this shape

- **Why forge's records, not sprue's journals?** Every Foundry deployment has them, sprue or not, so
  a map that needs only these files can show any protocol. `broadcast/<Script>.s.sol/<chain>/<sig>-latest.json`
  holds each transaction in order, with:
  - its type (CREATE, CREATE2, CALL), contract name and address, function and decoded arguments;
  - the contracts it created inside itself (`additionalContracts`, a factory's children);
  - receipts with status, block and logs.
- **Why not a UML diagram of the source?** sol2uml, Surya and Slither already draw source structure.
  None of the surveyed tools draws what was deployed: which address holds which contract, what each
  one was given at deploy, and who can change it. That is the question a reviewer asks.
- **Why no "permanent" edge?** A constructor argument is often stored as an immutable, but it can go to
  storage that a setter changes. The records cannot tell the two apart. Edges say what is known: set at
  deploy, or set by a call. A thick "permanent" edge is left for a later version: it needs the compiler's
  `immutableReferences` and the AST to prove that an argument fed an immutable.
- **Why a step player?** A deploy is a sequence. Reviewing it means asking what each step created or
  bound. Dimming what does not exist yet and marking what a step changed lets a reader follow it.
  Animation is an optional extra on top of the dimming. It stops under `prefers-reduced-motion`.

## Version 1

1. **Graph.** A node per deployed contract (name and short address) and per outside address: an EOA,
   a multisig or a contract the deployment did not create. Edges: *created by* (a factory's child),
   *set at deploy* (an address among a CREATE's arguments), *set by call* (an address passed in a call
   to a deployed contract, labelled with the function), *emitted* (a holder that a control event names),
   *implementation* (a proxy's current implementation or beacon from `Upgraded` or `BeaconUpgraded`, replayed
   per step; not control).
   Key every node by chain and address.
2. **Control lens, on by default.** Control comes from events first: the owner, pending owner, role
   holders and proxy admin that the receipts' logs name. They replay in order, so each step shows who
   holds what then. Where no event says it, names come second, as a heuristic: links whose parameter or
   function names control the target (owner, admin, role, minter, treasury, `transferOwnership`,
   `grantRole`, any `set*`/`bind*` with an address). Control links are drawn first, and contracts that
   an outside address controls are marked. The panel names each entry's source: the event or the rule
   that matched.
3. **Focus.** Hovering or selecting an address dims everything but its edges. A side panel lists the
   transactions behind each edge: step, function, arguments, transaction hash, block, status.
4. **Step player.** One step per transaction, or per sprue plan step when the project is a sprue one
   (the plan's step ids). A counter ("3/30"), previous/next, arrow keys and a scrubber. Contracts that
   do not exist yet are dimmed; what the step creates or binds is marked. A reverted transaction is
   shown as such and creates nothing.
5. **Table.** The same data as a table of transactions, for print, search and screen readers.

Optional sprue layer: role names from journals instead of contract names, a solid line for each link
that a certificate verified, and step ids. The on-chain address always stays visible. A step id comes
from a `<sig>-latest.json` file name. A transaction found only in an older `run-<timestamp>.json` has
no step id.

## Inputs and decoding

- `sprue map [--records <path>]... [--out <file>] [--title <text>] [<network>]` writes one offline HTML
  file with the data inlined. The page makes no network calls.
  - The project is the nearest directory up with `foundry.toml` or `sprue.json`. The `broadcast` and
    `out` paths come from `forge config --json` there, so `foundry.toml`, `FOUNDRY_PROFILE` and
    `FOUNDRY_*` apply. Forge must be installed, else exit 2.
  - The records hold the transactions. `out`, when present, holds the parameter names.
  - A network adds the sprue layer from `<paths.deployments>/<network>`.
  - Without a project, `--records` alone is enough.
  - The page goes to stdout, which must not be a terminal (exit 2). Redirect it, or name a file with
    `--out`, which replaces that file.
  - `sprue map --help` has the exit codes.
- Arguments are decoded from the calldata and the function signature, recursively for tuples and
  arrays. A call with no calldata uses the records' argument strings instead. A call whose calldata
  does not decode, including an array larger than the calldata, is left undecoded.
  Where no signature is known, the map shows the selector. A calldata word that holds a known address
  is still drawn as a link, flagged as not decoded. The same holds for such a word at the end of
  initcode that the records do not split into code and arguments (a factory's `bytes` argument, or a
  CREATE without `arguments`).
- `additionalContracts` is a flat list of every contract a transaction created. So a contract that a
  child's constructor created is drawn as the factory's child.
- Addresses are matched to nodes in a second pass, after every record is read. So a factory's child
  that a later call names is still linked. An address matches only by value.
- Parameter names: `functionAbi` for calls where forge records it; constructor parameter names from
  `<out>/<File>.sol/<Contract>.json` when it exists and its constructor's argument count matches the
  record; otherwise the argument's position. Many repositories commit records but not `out`, so the
  map must work without ABIs.
- Control events are profiles in `map/control.mjs`: one data shape per standard. A profile gives each
  event:
  - what it does (owner, pending owner, proxy admin, implementation, beacon, role granted, role revoked);
  - the parameter that holds the holder, and the role where there is one;
  - which parameters are indexed, and any alternative layout (ERC-1967's `AdminChanged` is read with
    non-indexed data words, or with indexed topics).
  A profile also lists its known role names.
  Built in: Ownable, Ownable2Step, AccessControl (OpenZeppelin and TimelockController role names) and
  ERC-1967.
- Events are matched by topic0. A log is read only when its topic count and data length fit a declared
  layout; any other log is skipped and counted in the stats (`eventsSkipped`).
- A log counts only from an address on the map. A role id shows by its name where a profile has one,
  else short; roles are told apart by their full id.
- A pending owner is not control. A transfer of an owner or proxy admin to the zero address shows as
  renounced. A role granted to the zero address shows as held by "anyone (zero address)".
- An event and a name-rule link that say the same thing in one transaction are one link with both sources.
- Several runs of one script (`run-<timestamp>.json`) are merged. A transaction is identified by its
  chain and hash, and appears once with its final receipt. Within a chain, mined transactions replay in
  block and transaction-index order, whatever file holds them.

## Development

`node --test map/test/*.test.mjs` runs on `map/test/token-vault`, which `map/test/fixture.sh`
regenerates.

## Not in version 1

A proxy's implementation read from the chain (the map follows ERC-1967 `Upgraded` and `BeaconUpgraded` logs only,
so a proxy that emitted neither shows no implementation), a diff between two deploys
or between a plan and the chain, token flows, and a full "who can call which function" matrix.

## Evidence (2026-10-21 survey)

- No surveyed tool draws a deployment graph from Foundry records. Hardhat Ignition's `visualize` draws a
  module's plan ([guide](https://hardhat.org/ignition/docs/guides/visualize)); Catapulta keeps per-deploy
  reports; foundry-devops reads records into JSON ([repo](https://github.com/mds1/foundry-devops)).
- Transaction tools show one transaction at a time: Phalcon's fund and invocation flows
  ([docs](https://docs.blocksec.com/phalcon/explorer)), Tenderly's trace and debugger
  ([docs](https://docs.tenderly.co/debugger)), Sentio ([docs](https://docs.sentio.xyz/sentio-debugger/trace-view)).
  Arkham's visualizer colours an edge by direction and opens a side panel on click
  ([docs](https://codex.arkm.com/the-intelligence-platform/visualizer)).
- Source tools: sol2uml ([repo](https://github.com/naddison36/sol2uml)), Surya
  ([repo](https://github.com/ConsenSys/surya)), Slither printers
  ([docs](https://secure-contracts.com/program-analysis/slither/docs/src/printers/Printer-documentation.html)).
  An auditor-facing permission graph has precedent in AraGraph for Aragon DAOs
  ([post](https://diligence.security/blog/2019/11/aragraph-dao-permissions-visualized/)).
- Large graphs fail by noise: Rover's issues ask to hide relationships
  ([issues](https://github.com/im2nguyen/rover/issues)); a guide recommends filtering past a few dozen
  resources ([post](https://spacelift.io/blog/terraform-graph)). Terraform plan visualizers mark each
  node's action ([repo](https://github.com/joachimdalen/terraform-plan-visualizer)); Pulumi starts from a
  table and offers the graph.
- Replay: Temporal fades groups unrelated to the selection and summarises per group
  ([post](https://temporal.io/blog/the-dark-magic-of-workflow-exploration)); Chrome's performance panel
  links a scrubbed moment to its cause ([docs](https://developer.chrome.com/docs/devtools/performance)).
  Animated transitions help readers track objects (Heer and Robertson, 2007), but animation alone did not
  improve comprehension in the studies found.
- The case for a control view: the 2025 Bybit loss came from a proxy implementation swap that signers
  could not see ([write-up](https://blockaid.io/blog/the-15b-bybit-hack-explained-a-technical-breakdown)).
- Gaps: no evidence of demand was found (no issue or thread asks for this); Cannon's and Metal's views
  were not verified.

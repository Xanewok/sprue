#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// The deploy graph runner. Node >= 18, no dependencies. It plans, asks and launches; every step is a
// `forge script` that runs without a shell, so a plan line is parsed into argv and never interpreted.
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { closeSync, mkdtempSync, openSync, readFileSync, readSync, rmSync, statSync, writeSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { dirname, join } from "node:path";

const NAME = "sprue";
const PROJECT = "sprue.json";
// Anvil's published dev key, which signs on a local chain when KEY is unset.
const DEV_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
// The one shape of a command line, as Graph._command prints it. Forge's output also carries the
// console.log of every contract the plan calls, so a line is run only if it matches whole.
const COMMAND =
  /^([A-Z][A-Z0-9_]*_RPC=\$[A-Z][A-Z0-9_]*_RPC )*forge script [A-Za-z0-9_./][A-Za-z0-9_./-]*(:[A-Za-z0-9_]+)? --sig '[A-Za-z_][A-Za-z0-9_]*\((string|string,uint8)\)' [a-z0-9][a-z0-9-]*( [0-9]+)?( --rpc-url (\$[A-Z][A-Z0-9_]*|[a-z][a-z0-9_-]*))? --sender (\$DEPLOYER|0x[0-9a-fA-F]{40})( --slow)?$/;
const SPACE = /[\t\n\v\f\r \u0085\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]/; // not JS's \s: it counts U+FEFF and misses U+0085
const WIN = process.platform === "win32";

const USAGE = `usage: ${NAME} list | json | mermaid [target] | plan <network> <target> | run [flags] <network> <target>

run flags may appear anywhere after the command.

  list                      the targets: nodes no other node depends on
  json                      the graph from the units' code; the saved export, graph.generated.json beside the graph script, is it
  mermaid [target]          a flowchart of the graph, or of what target depends on
  plan <network> <target>   the commands that reach target; reads $R, the default chain's RPC; sends nothing
  run [--wait] [--unsafe-unexpected-deployer] [--allow-dirty] [--account <name> | --ledger | --trezor] <network> <target>
                            sends what plan prints and plans again; needs R and DEPLOYER

On a network whose chains sprue.json lists all as local it sends unattended, sending from Anvil's unlocked
accounts, or signing with KEY (Anvil's dev key if unset) on another node. On any other chain it is attended: it needs a
terminal and no CI variable, refuses a development node unless the network is a rehearsal network (the name that paths.rehearsal ends in),
signs through exactly one of --account, --ledger and --trezor, as the step's sender, and starts only on a clean git checkout (uncommitted journals of an
interrupted run included: commit them). Each step's dry run is shown with its transactions and cost,
and every step is asked: it is sent only after \`yes\` is typed at the terminal, with no pending
transaction and the sender's nonces, the git HEAD and status (but for the journals the run writes),
.env and ~/.foundry/foundry.toml unchanged since before the dry run. Nothing skips the question.

--allow-dirty skips only the clean-checkout check at the start, with a warning, and never on a live
chain; the per-step comparison and the question stay.

--unsafe-unexpected-deployer lets a deploy step send with a key other than network.json's \`deployer\`
(it exports UNSAFE_UNEXPECTED_DEPLOYER=1 for this run; forge takes only the variable).

run stops with one of these; after a stop at 3 or 4, meet the condition and run it again, which
skips every node already done:

  0   the target is done
  1   a step or a clock read failed
  2   usage error, unknown target, \`--wait\` on the unlocked chain, an unknown plan line, or a refusal: no terminal,
      CI set, a development node, a signer other than the step's sender, a pending transaction
  3   a node it cannot reach yet (\`# cannot reach\`)
  4   a date the chain has not reached; --wait waits for it instead
  5   the target is not done: a plan is unchanged after its sends
  6   the person did not answer \`yes\`; the step was not sent
  *   forge's own code, when a step refuses
`;

class Exit extends Error {
  constructor(code) {
    super(`exit ${code}`);
    this.code = code;
  }
}
// Blocking, so a full non-blocking pipe loses no output and nothing is reordered by exit.
function write(fd, s) {
  const b = Buffer.from(s);
  for (let off = 0; off < b.length; ) {
    try {
      off += writeSync(fd, b, off);
    } catch (e) {
      if (e.code !== "EAGAIN") throw e;
    }
  }
}
const out = (s) => write(1, s);
const err = (s) => write(2, s);
const fail = (code, msg) => {
  err(`${NAME}: ${msg}\n`);
  throw new Exit(code);
};
const usageError = () => {
  err(USAGE);
  throw new Exit(2);
};
const isObject = (x) => x !== null && typeof x === "object" && !Array.isArray(x);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const readJson = (file) => {
  try { return JSON.parse(readFileSync(file, "utf8")); } catch {}
};
const isFile = (f) => {
  try { return statSync(f).isFile(); } catch { return false; }
};

// A short tool's stdout without its trailing newlines, like `$(...)`.
function exec(bin, args, stdio = ["ignore", "pipe", "inherit"]) {
  const r = spawnSync(bin, args, { encoding: "utf8", stdio });
  if (r.error) fail(1, `cannot run ${bin}: ${r.error.message}`);
  return { status: r.status ?? 1, out: (r.stdout ?? "").replace(/[\r\n]+$/, "") };
}
// Exits with the tool's code, or refuses with `refusal`.
function must(bin, args, refusal, stdio) {
  const r = exec(bin, args, stdio);
  if (r.status === 0) return r.out;
  if (refusal) fail(2, refusal);
  throw new Exit(r.status);
}
const clientVersion = (rpc) => exec("cast", ["rpc", "web3_clientVersion", "--rpc-url", rpc], ["ignore", "pipe", "ignore"]);
const isAnvil = (v) => v.status === 0 && v.out.replaceAll('"', "").startsWith("anvil/");
const chainId = (rpc) => must("cast", ["chain-id", "--rpc-url", rpc], `cannot read the chain id at ${rpc}`);

// forge's stdout and stderr share one file, so the output keeps the order forge wrote it in.
function forge(args, env) {
  const dir = mkdtempSync(join(tmpdir(), "sprue-"));
  const file = join(dir, "out");
  const fd = openSync(file, "w");
  let r;
  try {
    r = spawnSync("forge", args, { stdio: ["ignore", fd, fd], env: { ...process.env, ...env } });
  } finally {
    closeSync(fd);
  }
  const text = readFileSync(file, "utf8");
  rmSync(dir, { recursive: true, force: true });
  if (r.error) fail(1, `cannot run forge: ${r.error.message}`);
  return { status: r.status ?? 1, text: text.replace(/\n+$/, "") };
}

// The graph script's lines that start with `<tag> `, without the tag.
function graph(GRAPH, tag, sig, ...rest) {
  const r = forge(["script", GRAPH, "--sig", sig, ...rest]);
  if (r.status !== 0) {
    err(`${r.text}\n`);
    throw new Exit(1);
  }
  return r.text.split("\n").flatMap((l) => {
    const m = new RegExp(`^ *${tag} (.*)$`).exec(l.replace(/\r$/, ""));
    return m ? [m[1]] : [];
  });
}

// The question goes to the terminal, never to stdin or stdout, so a pipe cannot answer it. A terminal
// that cannot open or has no more input is no answer.
function openTty() {
  try { return [openSync(WIN ? "CONIN$" : "/dev/tty", "r"), openSync(WIN ? "CONOUT$" : "/dev/tty", "w")]; } catch {}
}
function ask(prompt) {
  const tty = openTty();
  if (!tty) fail(2, "refusing: no terminal to ask on");
  const [rd, wr] = tty;
  write(wr, prompt);
  const bytes = [];
  const b = Buffer.alloc(1);
  for (;;) {
    let n;
    try {
      n = readSync(rd, b, 0, 1, null);
    } catch (e) {
      if (e.code === "EAGAIN") continue;
      break;
    }
    if (n === 0 || b[0] === 10) break;
    bytes.push(b[0]);
  }
  closeSync(rd);
  closeSync(wr);
  const answer = Buffer.from(bytes).toString();
  return WIN ? answer.replace(/\r$/, "") : answer;
}

// A plan line that COMMAND matched whole, as forge's environment and argv. A `$NAME` is one argument
// whatever it holds, and COMMAND lists the only names a line can use.
function parse(line) {
  const env = {};
  const args = [];
  const toks = line.split(" ");
  let i = 0;
  for (; toks[i] !== "forge"; i++) {
    const [key, name] = toks[i].split("=$");
    env[key] = process.env[name] ?? "";
  }
  for (i++; i < toks.length; i++) {
    const t = toks[i];
    if (t[0] !== "$") args.push(t[0] === "'" ? t.slice(1, -1) : t);
    else if (process.env[t.slice(1)]) args.push(process.env[t.slice(1)]);
    else fail(2, `refusing: ${t} is not set`);
  }
  return { env, args };
}

function mermaid(g, target) {
  let ns = g.nodes;
  if (target) {
    const by = new Map(ns.map((n) => [n.id, n]));
    const keep = new Set();
    const close = (id) => {
      if (keep.has(id)) return;
      keep.add(id);
      for (const d of by.get(id).dependencies) close(d);
    };
    close(target);
    ns = ns.filter((n) => keep.has(n.id));
  }
  const k = (s) => "n" + String(s).replace(/[^A-Za-z0-9]/gu, "_");
  // By code point, which is UTF-8 byte order and not JS's UTF-16 order.
  const units = [...new Set(ns.map((n) => n.unit))].sort((a, b) => Buffer.compare(Buffer.from(String(a)), Buffer.from(String(b))));
  const lines = ["flowchart TD"];
  for (const unit of units) {
    lines.push(`subgraph ${k(unit)}["${unit}"]`);
    for (const n of ns.filter((m) => m.unit === unit)) {
      const tf = n.flags?.testOnly;
      lines.push(`  ${k(n.id)}${n.kind === "predicate" ? `(["${n.id}"])` : `["${n.id}"]`}${tf != null && tf !== false ? ":::testOnly" : ""}`);
    }
    lines.push("end");
  }
  for (const n of ns) for (const d of n.dependencies) lines.push(`${k(d)} --> ${k(n.id)}`);
  lines.push("classDef testOnly stroke-dasharray: 4 3");
  out(lines.join("\n") + "\n");
}

async function main(argv) {
  if (argv[0] === "-h" || argv[0] === "--help") {
    out(USAGE);
    return 0;
  }
  // The project root is the nearest directory, from the current one up, that holds sprue.json. This
  // runner validates `paths` itself, because it needs them before forge can run, and reads only the
  // few `chains` fields it uses. Chains.sol validates the whole file in every `FileGraph` `plan`, and a
  // plan precedes every send.
  let root = process.cwd();
  while (!isFile(join(root, PROJECT))) {
    if (dirname(root) === root) fail(2, `refusing: no ${PROJECT} in ${process.cwd()} or above`);
    root = dirname(root);
  }
  process.chdir(root);
  const project = readJson(PROJECT);
  const keys = (o) => Object.keys(o).sort().join();
  if (
    !(
      isObject(project) &&
      keys(project) === "chains,paths" &&
      isObject(project.chains) &&
      isObject(project.paths) &&
      keys(project.paths) === "deployments,graph,rehearsal,units" &&
      Object.values(project.paths).every((v) => typeof v === "string" && v.length > 0 && !SPACE.test(v))
    )
  ) {
    fail(2, `refusing: ${PROJECT} is not a file of exactly paths and chains, with the non-empty, whitespace-free paths deployments, graph, rehearsal and units`);
  }
  const { deployments: DEPLOYMENTS, graph: GRAPH_SCRIPT, rehearsal: REHEARSAL } = project.paths;
  // The graph contract is named like its script file, and the saved export lies beside it.
  const slash = GRAPH_SCRIPT.lastIndexOf("/");
  const GRAPH = `${GRAPH_SCRIPT}:${GRAPH_SCRIPT.slice(slash + 1).replace(/\.s\.sol$/, "")}`;
  const GRAPH_JSON = `${slash < 0 ? "" : GRAPH_SCRIPT.slice(0, slash) + "/"}graph.generated.json`;
  // A rehearsal network is <prefix> or <prefix>-<suffix>, a plain name under the deployments directory.
  // The runner checks that git ignores `<prefix>` and `<prefix>-x`, as a sample of the project's ignore
  // rule for every rehearsal directory. Keeping that rule complete is the project's job. Calling forge
  // directly bypasses this check.
  const rehearsal = REHEARSAL.startsWith(`${DEPLOYMENTS}/`) ? REHEARSAL.slice(DEPLOYMENTS.length + 1) : "";
  if (!/^[a-z0-9][a-z0-9-]*$/.test(rehearsal)) fail(2, `refusing: ${PROJECT}'s paths.rehearsal is not ${DEPLOYMENTS}/<lower-case name>`);
  const ignored = (d) => exec("git", ["check-ignore", "-q", d], ["ignore", "ignore", "ignore"]).status === 0;
  if (!(ignored(`${REHEARSAL}/`) && ignored(`${REHEARSAL}-x/`))) {
    fail(2, "refusing: git does not ignore the directories <paths.rehearsal> and <paths.rehearsal>-*, where a rehearsal writes");
  }

  const exported = () => {
    const g = readJson(GRAPH_JSON);
    return isObject(g) && Array.isArray(g.nodes) ? g : undefined;
  };
  const known = (t) => {
    if (!exported()?.nodes.some((n) => n?.id === t)) fail(2, `cannot reach ${t}: unknown target; see ${NAME} list, or regenerate graph.generated.json if the graph changed`);
  };

  const [verb, ...rest] = argv;
  if (verb === "list" || verb === "json") {
    if (rest.length) usageError();
    for (const l of graph(GRAPH, verb === "list" ? "TARGET" : "GRAPH", verb === "list" ? "list()" : "graph()")) out(`${l}\n`);
    return 0;
  }
  if (verb === "mermaid") {
    if (rest.length > 1) usageError();
    const only = rest[0] ?? "";
    if (only) known(only);
    // Reads graph.generated.json, not forge, so the chart shows exactly the saved export.
    const g = exported();
    if (!g) fail(2, `cannot read ${GRAPH_JSON}`);
    mermaid(g, only);
    return 0;
  }
  if (verb !== "plan" && verb !== "run") usageError();

  // Flags may stand anywhere. The other arguments keep their order.
  let wait = false, dirtyOk = false;
  const signers = [];
  // Only `attend` sets it, per step: an inherited value would stamp a clean run's roles dirty.
  delete process.env.DEPLOY_TREE_DIRTY;
  const pos = [];
  for (let i = 0; i < rest.length; i++) {
    const a = rest[i];
    if (verb !== "run") pos.push(a);
    else if (a === "--wait") wait = true;
    else if (a === "--unsafe-unexpected-deployer") process.env.UNSAFE_UNEXPECTED_DEPLOYER = "1";
    else if (a === "--allow-dirty") dirtyOk = true;
    else if (a === "--account") {
      if (++i >= rest.length) usageError();
      signers.push([a, rest[i]]);
    } else if (a === "--ledger" || a === "--trezor") signers.push([a]);
    else pos.push(a);
  }
  if (pos.length !== 2 || !pos[0] || !pos[1]) usageError();
  const [network, target] = pos;
  // The network name is printed into every command, so a space or a newline in it would add flags.
  if (!/^[a-z0-9][a-z0-9-]*$/.test(network)) fail(2, `refusing network '${network}': not a plain name`);
  const netfile = `${DEPLOYMENTS}/${network}/network.json`;
  if (!isFile(netfile)) fail(2, `unknown network '${network}': no ${netfile}`);
  known(target);
  const R = process.env.R ?? "";
  if (!R) fail(2, "set R to the RPC the plan reads");
  const plan = () => graph(GRAPH, "PLAN", "plan(string,string)", network, target, "--rpc-url", R);
  if (verb === "plan") {
    for (const l of plan()) out(`${l}\n`);
    return 0;
  }
  const DEPLOYER = process.env.DEPLOYER ?? "";
  if (!DEPLOYER) fail(2, "set DEPLOYER to the sender of steps without .by");
  if (!/^0x[0-9a-fA-F]{40}$/.test(DEPLOYER)) fail(2, "DEPLOYER is not a 0x address");

  // git status as the person sees it. Configuration (status.showUntrackedFiles, diff.ignoreSubmodules)
  // must not hide an untracked file or a dirty submodule, and a failing git is a refusal, never an empty
  // status.
  const porcelain = () => {
    const s = must("git", ["status", "--porcelain", "--untracked-files=all", "--ignore-submodules=none"], "refusing: git status failed");
    return s === "" ? [] : s.split("\n");
  };
  const units = new Set(exported().nodes.map((n) => n.unit).filter((u) => typeof u === "string" && u));
  const net = readJson(netfile);
  const chainMap = isObject(net) ? net.chains || {} : undefined;
  if (!isObject(chainMap) || !Object.keys(chainMap).every((c) => /^[a-z][a-z0-9]*$/.test(c))) {
    fail(2, `refusing ${network}: a chain's name is not a plain lower-case name`);
  }
  const chains = Object.keys(chainMap);
  // The default chain: sprue.json's chains.default, which the network must have, else its only chain,
  // else none (a step without .on then refuses at plan).
  let home = project.chains.default;
  if (home != null && home !== false && home !== "") {
    home = String(home);
    if (!chainMap[home]) fail(2, `refusing ${network}: network.json has no chain ${home}, which ${PROJECT} names as chains.default`);
  } else home = chains.length === 1 ? chains[0] : "";
  // Local: every chain of the network is listed in sprue.json's chains.local, so a send needs no
  // person. This only picks the signer. `plan`, which precedes every send, refuses a malformed list.
  const isLocal = (id) => Array.isArray(project.chains.local) && project.chains.local.includes(id);
  let anvil = false;
  let signer = [];
  const attended = !(chains.length > 0 && chains.every((c) => isLocal(chainMap[c]?.id)));
  if (!attended) {
    // Anvil can send as any address a step names, which need not be the dev key's. Any other node
    // signs with a single key.
    anvil = isAnvil(clientVersion(R));
    signer = anvil ? ["--unlocked"] : ["--private-key", process.env.KEY || DEV_KEY];
    if (wait && anvil) fail(2, "--wait has no use on Anvil: it moves the clock itself");
  }
  // Each endpoint must serve the chain that network.json names. With FOUNDRY_CHAIN_ID set, forge's own
  // chain check reads the variable and not the node, so the preview would show the network's chain for
  // a send to another node.
  const expectChain = (rpc, id) => {
    if (!rpc) return;
    const got = chainId(rpc);
    if (got !== String(id)) fail(2, `refusing ${network}: ${rpc} is chain ${got}, network.json says ${id}`);
  };
  // A chain's rpc alias is printed into the commands, like the network name. A date line tells an alias
  // from an RPC variable by its lower case.
  const aliases = Object.values(chainMap).map((c) => c?.rpc).filter((a) => a != null && a !== false);
  if (!aliases.every((a) => typeof a === "string" && /^[a-z][a-z0-9_-]*$/.test(a))) fail(2, `refusing ${network}: a chain's rpc alias is not a plain name`);
  const endpoints = [R];
  for (const c of chains) {
    // A chain's RPC: its alias, else the <CHAIN>_RPC variable. $R also serves the default chain.
    const rpc = chainMap[c]?.rpc || process.env[`${c.toUpperCase()}_RPC`] || "";
    expectChain(rpc, chainMap[c].id);
    if (c === home) expectChain(R, chainMap[c].id);
    if (rpc) endpoints.push(rpc);
  }
  let me = "";
  if (attended) {
    // Not stdin: the question is read from the terminal, so it is the terminal that must open.
    if ("CI" in process.env) fail(2, `refusing ${network}: CI is set; a person at a terminal sends to a public chain`);
    const tty = openTty();
    if (!tty) fail(2, `refusing ${network}: no terminal to ask on`);
    for (const fd of tty) closeSync(fd);
    if (signers.length !== 1) fail(2, "sign with exactly one of --account, --ledger and --trezor");
    if (dirtyOk) {
      // A live chain deploys only from a clean commit, so refuse if any chain is live. The kinds come
      // from the `# chain` lines that `plan` prints. Refuse too if no kind is seen.
      const kinds = plan().flatMap((l) => {
        const m = /^# chain [^ ]* [0-9]* (.*)$/.exec(l);
        return m ? [m[1]] : [];
      });
      if (!kinds.join("\n") || kinds.includes("live")) {
        fail(2, `refusing --allow-dirty: ${network} has a live chain (or no chain kind), which deploys from a clean commit`);
      }
      out("warning: --allow-dirty: the working tree is not required to be clean\n");
    } else if (porcelain().length) {
      fail(2, "refusing: the working tree is not clean; commit it (the journals of an interrupted run too), or on a test chain pass --allow-dirty");
    }
    // Outside a rehearsal network a development node is refused: a run on a fork or devnet would write
    // the network's committed journals and records.
    if (network !== rehearsal && !network.startsWith(`${rehearsal}-`)) {
      for (const rpc of endpoints) {
        const v = clientVersion(rpc);
        if (v.status !== 0) fail(2, `cannot read the node at ${rpc}`);
        const id = chainId(rpc);
        if (isAnvil(v) || isLocal(Number(id))) {
          fail(2, `refusing ${network}: ${rpc} is a development node (${v.out}, chain ${id}); rehearse on a ${rehearsal}-* network`);
        }
      }
    }
    signer = signers[0];
    me = must("cast", ["wallet", "address", ...signer], undefined, ["inherit", "pipe", "inherit"]);
    out(`signer ${me}\n`);
  }

  // The sender's latest nonce on each endpoint, refusing if it has a pending transaction at any.
  const nonces = (sender) =>
    endpoints
      .map((rpc) => {
        const at = (block) => must("cast", ["nonce", sender, "--block", block, "--rpc-url", rpc]);
        const latest = at("latest");
        if (latest !== at("pending")) fail(2, `refusing: ${sender} has a pending transaction at ${rpc}; wait for it or replace it`);
        return `${latest} `;
      })
      .join("");
  // The working-tree changes that matter while the person is asked to confirm: git status, minus the
  // journals and metadata the run itself writes (<unit>.json and *.metadata.json). Known gap: the send
  // runs forge again, so any other state that forge reads may differ from the dry run the person saw.
  const changes = () => {
    const dir = `${DEPLOYMENTS}/${network}/`;
    return porcelain().filter((l) => {
      const p = l.slice(3);
      return !(p.startsWith(dir) && (p.endsWith(".metadata.json") || (p.endsWith(".json") && units.has(p.slice(dir.length, -5)))));
    });
  };
  // The untracked records that this run's own earlier sends created (ownership is by path) do not make
  // a later step dirty. `tree`, the approval comparison, does not filter them: a new record path that
  // appears while the question waits makes the send refuse. Rewriting an existing untracked path does
  // not.
  const ours = new Set();
  const digest = (f) => (isFile(f) ? [`${f} ${createHash("sha256").update(readFileSync(f)).digest("hex")}`] : []);
  const tree = () => [...changes(), ...digest(".env"), ...digest(join(homedir(), ".foundry", "foundry.toml"))].join("\n");
  const head = () => must("git", ["rev-parse", "HEAD"], "refusing: git rev-parse failed");

  // Repeats forge's last `Error:` line, where a long run buries it, and exits with forge's code.
  const stop = (text, code) => {
    const e = text.split("\n").filter((l) => l.startsWith("Error:")).pop();
    if (e) err(`${e}\n`);
    throw new Exit(code);
  };
  // Runs forge with its output streaming.
  const step = async ({ env, args }) => {
    const { code, log } = await new Promise((resolve) => {
      const child = spawn("forge", [...args, "--broadcast", ...signer], { env: { ...process.env, ...env }, stdio: ["ignore", "pipe", "pipe"] });
      let log = "";
      for (const s of [child.stdout, child.stderr]) {
        s.setEncoding("utf8");
        s.on("data", (d) => {
          out(d);
          log += d;
        });
      }
      child.on("error", (e) => {
        err(`${NAME}: cannot run forge: ${e.message}\n`);
        resolve({ code: 1, log: "" });
      });
      child.on("close", (code) => resolve({ code: code ?? 1, log }));
    });
    if (code !== 0) stop(log, code);
  };

  // Shows the line's dry run, and sends it only if the person at the terminal answers yes.
  async function attend(line, cmd) {
    const sender = cmd.args[cmd.args.indexOf("--sender") + 1];
    if (sender.toLowerCase() !== me.toLowerCase()) fail(2, `refusing: this step sends as ${sender}, not the signer ${me}: ${line}`);
    const snap = nonces(sender);
    const sha = head();
    const seen = tree();
    // The journal records this for a role the step creates: the tree at the send, not at a later
    // recovery.
    if (changes().some((l) => !ours.has(l))) process.env.DEPLOY_TREE_DIRTY = "1";
    else delete process.env.DEPLOY_TREE_DIRTY;
    const dry = forge(cmd.args, cmd.env);
    out(`${dry.text}\n`);
    if (dry.status !== 0) stop(dry.text, dry.status);
    // Forge saves a dry run that has transactions and names the file. If the output says it has
    // transactions but names no file, they cannot be shown, so refuse.
    const records = dry.text.split("\n").flatMap((l) => (l.startsWith("Transactions saved to: ") ? [l.slice(23)] : []));
    const show = (v) => (v == null ? "null" : typeof v === "string" ? v : JSON.stringify(v));
    for (const f of records) {
      try {
        const rec = readJson(f);
        for (const d of rec.deployments ?? [rec]) {
          for (const t of d.transactions) {
            out(`  chain ${show(d.chain)} nonce ${show(t.transaction.nonce)}: ${show(t.transactionType)} ${t.contractName ?? ""} ${show(t.contractAddress ?? t.transaction.to)} value ${show(t.transaction.value)} ${t.function ?? ""} ${JSON.stringify(t.arguments ?? [])}\n`);
          }
        }
      } catch {
        fail(2, `refusing: cannot show the dry run's record ${f}`);
      }
    }
    if (!records.length) {
      if (/^SIMULATION COMPLETE/m.test(dry.text)) fail(2, "refusing: the dry run has transactions but names no record to show");
      out("  no transactions in the dry run\n");
    }
    if (ask(`${line}\nSend this as ${sender}? Type yes: `) !== "yes") fail(6, "not sent: the answer was not yes");
    if (nonces(sender) !== snap) fail(2, "refusing: the sender's nonce moved since before the dry run; run again");
    if (head() !== sha) fail(2, "refusing: HEAD moved since before the dry run; run again");
    if (tree() !== seen) fail(2, "refusing: the working tree changed since before the dry run; run again");
    const pre = new Set(porcelain());
    await step(cmd);
    // Ownership is by path: the new untracked records under this step's script directory (its chain id
    // is not known here). A concurrent run of the same script is not told apart.
    const script = cmd.args[1].split(":")[0].split("/").pop();
    for (const l of porcelain()) if (l.startsWith(`?? broadcast/${script}/`) && !pre.has(l)) ours.add(l);
  }

  // A date line names the RPC variable or alias of its chain (`# not before <ts> on <CHAIN>_RPC ...`).
  // Without `on`, the clock is $R's.
  const before = (line, at, on) => {
    let clock = R;
    if (on) {
      if (/[^A-Za-z0-9_-]/.test(on)) fail(2, `unknown plan line: ${line}`);
      // An RPC variable's name is upper case; anything else is a foundry.toml alias, which cast resolves.
      clock = /[^A-Z0-9_]/.test(on) ? on : process.env[on] || fail(2, `refusing: ${on} is not set`);
    }
    const now = must("cast", ["block", "latest", "--field", "timestamp", "--rpc-url", clock]);
    if (!/^[0-9]+$/.test(now)) fail(1, `cannot read the clock at ${clock}`);
    return { late: BigInt(now) < BigInt(at), clock };
  };
  const quiet = ["ignore", "ignore", "inherit"];
  let sent = "";
  outer: for (;;) {
    const text = plan().join("\n").replace(/\n+$/, "");
    // A plan equal to the one just sent shows no progress in planning. Stop instead of sending the same
    // commands again.
    if (sent && text === sent) fail(5, `cannot reach ${target}: its plan is unchanged after sending it`);
    for (const line of text.split("\n")) {
      if (line.startsWith("# not before ")) {
        const [at, ...r] = line.slice(13).split(" ");
        const on = r[0] === "on" ? r[1] : "";
        if (!/^[0-9]+$/.test(at)) fail(2, `unknown plan line: ${line}`);
        let b = before(line, at, on);
        if (b.late) {
          if (anvil && isAnvil(clientVersion(b.clock))) {
            must("cast", ["rpc", "evm_setNextBlockTimestamp", at, "--rpc-url", b.clock], undefined, quiet);
            must("cast", ["rpc", "evm_mine", "--rpc-url", b.clock], undefined, quiet);
          } else {
            if (!wait) fail(4, line);
            out(`${line}: waiting\n`);
            while (b.late) {
              await sleep(5000);
              b = before(line, at, on);
            }
          }
          // The rest of this plan was judged before the date, so plan again.
          continue outer;
        }
      } else if (line.startsWith("# then plan again ")) {
        sent = text;
        continue outer;
      } else if (line.startsWith("# cannot reach ")) {
        // The step's command follows and would refuse, so it is not sent.
        out(`${line}\n`);
        throw new Exit(3);
      } else if (line.startsWith("# chain ") || line.startsWith("# done ")) out(`${line}\n`);
      else if (line.startsWith("#") || (line && !COMMAND.test(line))) fail(2, `unknown plan line: ${line}`);
      else if (line) {
        const cmd = parse(line);
        sent = text;
        await (attended ? attend(line, cmd) : step(cmd));
      }
    }
    // Judge what the sends left: a plan with nothing to send, even an empty one, ends the run.
    if (!(sent && sent === text)) return 0;
  }
}

const argv = process.argv.slice(2);
if (argv.length === 1 && (argv[0] === "--version" || argv[0] === "-v")) {
  console.log(JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8")).version);
} else {
  try {
    process.exitCode = await main(argv);
  } catch (e) {
    if (!(e instanceof Exit)) throw e;
    process.exitCode = e.code;
  }
}

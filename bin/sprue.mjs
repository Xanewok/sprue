#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// The deploy graph runner. Node >= 18, no dependencies. It plans, asks and launches; every step is a
// `forge script` that runs without a shell, so a plan line is parsed into argv and never interpreted.
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  closeSync, copyFileSync, existsSync, mkdirSync, mkdtempSync, openSync, readFileSync, readSync, readdirSync, rmSync, statSync,
  writeFileSync, writeSync,
} from "node:fs";
import { homedir, tmpdir } from "node:os";
import { dirname, join } from "node:path";

const NAME = "sprue";
const PROJECT = "sprue.json";
// Anvil's published dev key, which signs on a local chain when KEY is unset.
const DEV_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
// The one shape of a command line, as Graph._command prints it. Forge's output also carries the
// console.log of every contract the plan calls, so a line is run only if it matches whole.
const COMMAND =
  /^(FOUNDRY_BROADCAST=[A-Za-z0-9_./-]+ FOUNDRY_CACHE_PATH=[A-Za-z0-9_./-]+ )?forge script [A-Za-z0-9_./][A-Za-z0-9_./-]*(:[A-Za-z0-9_]+)? --sig '[A-Za-z_][A-Za-z0-9_]*\((string|string,uint8)\)' [a-z0-9][a-z0-9-]*( [0-9]+)?( --rpc-url ([a-z][a-z0-9_-]*|http:\/\/127\.0\.0\.1:[0-9]+))? --sender (\$DEPLOYER|0x[0-9a-fA-F]{40})( --slow)?$/;
// A chain's rpc: a foundry.toml [rpc_endpoints] alias, or, only in a rehearsal copy, its fork's URL.
const ALIAS = /^[a-z][a-z0-9_-]*$/;
const LOOPBACK = /^http:\/\/127\.0\.0\.1:[0-9]+$/;
// A network names a directory, and Windows reserves these names in any case.
const DEVICE = /^(con|prn|aux|nul|com[1-9]|lpt[1-9])$/i;
const WIN = process.platform === "win32";
// Windows refuses, for a moment, to remove a file that another process still holds open (EBUSY, EPERM).
const RM_TREE = { recursive: true, force: true, maxRetries: 5, retryDelay: 100 };

const USAGE = `usage: ${NAME} list | json | mermaid [target] | plan <network> <target> | run [flags] <network> <target>
       ${NAME} rehearse [flags] <network> <target> | rehearse --stop <network>

Flags may appear anywhere after the command.

  list                      the targets: nodes no other node depends on
  json                      the graph from the units' code; the saved export, graph.generated.json beside the graph script, is it
  mermaid [target]          a flowchart of the graph, or of what target depends on
  plan <network> <target>   the commands that reach target; reads the default chain's rpc; sends nothing
  run [--wait] [--unsafe-unexpected-deployer] [--allow-dirty] [--account <name> | --ledger | --trezor] <network> <target>
                            sends what plan prints and plans again; DEPLOYER defaults to the pinned deployer, else the signer
  rehearse [--keep] [--block [<chain>=]<n>]... [--unsafe-unexpected-deployer] <network> <target>
                            runs target on Anvil forks of network's chains, which it starts, in a fresh copy
                            <paths.rehearsal>-<network> of network's files; impersonates each step's sender
  rehearse --stop <network> stops the forks that rehearse --keep left running

run, on a network whose chains sprue.json lists all as local, sends unattended, sending from Anvil's unlocked
accounts, or signing with KEY (Anvil's dev key if unset) on another node. On any other chain it is attended: it needs a
terminal and no CI variable. A rehearsal network (the name that paths.rehearsal ends in, or it and -<suffix>) requires
Anvil or a chains.local id on every chain; any other network refuses a development node. It signs through exactly one of --account, --ledger and --trezor, as the step's sender, and starts only on a clean git checkout (uncommitted journals of an
interrupted run included: commit them). Each step's dry run is shown with its transactions and cost,
and every step is asked: it is sent only after \`yes\` is typed at the terminal, with no pending
transaction and the sender's nonces, the git HEAD and status (but for the journals the run writes),
.env and ~/.foundry/foundry.toml unchanged since before the dry run, and only if the dry run, run again
after yes, would send the same transactions. Nothing skips the question.

--allow-dirty skips only the clean-checkout check at the start, with a warning, and never on a live
chain; the per-step comparison and the question stay.

--unsafe-unexpected-deployer lets the steps of network.json's \`deployer\` send as DEPLOYER, or as the
signer when the run cannot sign as the pin (it exports UNSAFE_UNEXPECTED_DEPLOYER=1; forge takes only the variable).

Every chain of network.json names its rpc: an alias of foundry.toml's [rpc_endpoints], which forge and
cast resolve, with .env.

rehearse forks each chain from its rpc, at the latest block or --block's. Each rehearse starts over: it
stops the forks a --keep left and copies network's files again, journals included, with each chain's
rpc replaced by its fork's URL. It runs unattended and on a dirty tree, takes no signer flag, sets the
forks' clocks to each date, and stops the forks at the end. With --keep they keep running.

run and rehearse stop with one of these. After a stop at 3 or 4, meet the condition and run it again: run
skips every node already done, rehearse starts over from network's files:

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
  const r = spawnSync(bin, args, { encoding: "utf8", stdio, maxBuffer: 1 << 28 });
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
// forge and cast take a resolved eth_rpc_url or sender over a line's --rpc-url and --sender (a FOUNDRY_*
// variable, also from .env, beats the flag), so the line shown would not be the one that runs. A variable
// set to forge's default sender overrides too, though config shows no difference, so names count. forge
// reads each prefix in any case.
const OVERRIDE = /^(foundry|dapp|dapp_test)_(eth_rpc_url|sender|rpc_endpoints)$/i;
const overriding = (config, env) => {
  const dotenv = isFile(".env") ? readFileSync(".env", "utf8") : "";
  const names = [...Object.keys(env), ...[...dotenv.matchAll(/^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=/gm)].map((m) => m[1])];
  return [
    ...new Set(names.filter((v) => OVERRIDE.test(v))),
    ...(config.eth_rpc_url != null ? ["eth_rpc_url"] : []),
    ...(config.sender != null && String(config.sender).toLowerCase() !== "0x1804c8ab1f12e6bbf3894d4083f33e07309d1f38" ? ["sender"] : []),
  ];
};

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
  rmSync(dir, RM_TREE);
  if (r.error) fail(1, `cannot run forge: ${r.error.message}`);
  return { status: r.status ?? 1, text: text.replace(/\n+$/, "") };
}

// `forge`, but a compile's lines are also copied to stderr while forge runs: forge reports a compile on
// the stdout that is captured, so a cold build of a large graph would otherwise wait in silence.
function forgeShowingCompile(args, env) {
  const dir = mkdtempSync(join(tmpdir(), "sprue-"));
  const file = join(dir, "out");
  const fd = openSync(file, "w");
  let read = 0;
  let shown = "";
  // Undecided until forge says whether it compiles; forge compiles before the script logs anything.
  let showing;
  // Only whole lines are taken, so a character still being written is never decoded.
  const follow = () => {
    const text = readFileSync(file, "utf8");
    for (let i; showing !== false && (i = text.indexOf("\n", read)) >= 0; read = i + 1) {
      const line = text.slice(read, i + 1);
      if (line.startsWith("No files changed")) showing = false;
      else if (line.startsWith("Compiling ")) showing = true;
      if (!showing) continue;
      err(line);
      shown += line;
      if (/^(Error: )?Compiler run/.test(line)) showing = false;
    }
    return text;
  };
  return new Promise((resolve) => {
    // Tracked so that an interrupt stops it before rehearse releases its lock.
    const child = (forgeStep = spawn("forge", args, { stdio: ["ignore", fd, fd], env: { ...process.env, ...env } }));
    const timer = setInterval(follow, 200);
    let ended = false;
    const end = (status, error) => {
      if (ended) return;
      ended = true;
      forgeStep = undefined;
      clearInterval(timer);
      const text = follow();
      closeSync(fd);
      rmSync(dir, RM_TREE);
      resolve({ status: status ?? 1, text: text.replace(/\n+$/, ""), shown, error });
    };
    child.on("error", (e) => end(1, e));
    child.on("close", (code) => end(code));
  });
}

// The graph script's lines that start with `<tag> `, without the tag.
async function graph(GRAPH, tag, sig, rest = [], env = {}) {
  const r = await forgeShowingCompile(["script", GRAPH, "--sig", sig, ...rest], env);
  if (r.error) fail(1, `cannot run forge: ${r.error.message}`);
  if (r.status !== 0) {
    err(`${r.text.replace(r.shown, "")}\n`);
    throw new Exit(1);
  }
  return r.text.split("\n").flatMap((l) => {
    const m = new RegExp(`^ *${tag} (.*)$`, "s").exec(l.replace(/\r$/, ""));
    return m ? [m[1]] : [];
  });
}

// The question goes to the terminal, never to stdin or stdout, so a pipe cannot answer it. A terminal
// that cannot open or has no more input is no answer. Windows documents OPEN_EXISTING for a console
// handle, and "w" asks for CREATE_ALWAYS.
function openTty() {
  try { return [openSync(WIN ? "CONIN$" : "/dev/tty", "r"), openSync(WIN ? "CONOUT$" : "/dev/tty", WIN ? "r+" : "w")]; } catch {}
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

// COMMAND admits only literal assignments and $DEPLOYER, which stays one argument.
function parse(line) {
  const toks = line.split(" ");
  const at = toks.indexOf("forge");
  const env = Object.fromEntries(toks.slice(0, at).map((t) => t.split("=")));
  const args = toks.slice(at + 1).map((t) => t === "$DEPLOYER" ? process.env.DEPLOYER : t[0] === "'" ? t.slice(1, -1) : t);
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
      // Plan lines carry the paths unquoted.
      Object.values(project.paths).every((v) => typeof v === "string" && /^[A-Za-z0-9_./-]+$/.test(v))
    )
  ) {
    fail(2, `refusing: ${PROJECT} must hold exactly paths and chains; paths must hold exactly deployments, graph, rehearsal and units, as nonempty strings using only A-Z a-z 0-9 _ . / -`);
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
  if (DEVICE.test(rehearsal)) fail(2, `refusing: ${PROJECT}'s paths.rehearsal ends in the directory ${rehearsal}, a name Windows reserves; rename it`);
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
    for (const l of await graph(GRAPH, verb === "list" ? "TARGET" : "GRAPH", verb === "list" ? "list()" : "graph()")) out(`${l}\n`);
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
  if (verb !== "plan" && verb !== "run" && verb !== "rehearse") usageError();
  const rehearsing = verb === "rehearse";

  // Flags may stand anywhere. The other arguments keep their order.
  let wait = false, dirtyOk = false, keep = false, stopOnly = false;
  const signers = [], blocks = [];
  // Only `attend` and `rehearse` set it: an inherited value would stamp a clean run's roles dirty.
  delete process.env.DEPLOY_TREE_DIRTY;
  const pos = [];
  for (let i = 0; i < rest.length; i++) {
    const a = rest[i];
    if (verb === "plan") pos.push(a);
    else if (a === "--unsafe-unexpected-deployer") process.env.UNSAFE_UNEXPECTED_DEPLOYER = "1";
    else if (a === "--account" || a === "--ledger" || a === "--trezor") {
      if (rehearsing) fail(2, `refusing ${a}: rehearse sends as each step's sender on its forks, and no key signs`);
      if (a === "--account" && ++i >= rest.length) usageError();
      signers.push(a === "--account" ? [a, rest[i]] : [a]);
    } else if (rehearsing && a === "--keep") keep = true;
    else if (rehearsing && a === "--stop") stopOnly = true;
    else if (rehearsing && a === "--block") {
      if (++i >= rest.length) usageError();
      blocks.push(rest[i]);
    } else if (!rehearsing && a === "--wait") wait = true;
    else if (!rehearsing && a === "--allow-dirty") dirtyOk = true;
    else pos.push(a);
  }
  if (pos.length !== (stopOnly ? 1 : 2) || pos.some((p) => !p) || (stopOnly && (keep || blocks.length))) usageError();
  let [network, target] = pos;
  // The network name is printed into every command, so a space or a newline in it would add flags.
  if (!/^[a-z0-9][a-z0-9-]*$/.test(network)) fail(2, `refusing network '${network}': not a plain name`);
  if (DEVICE.test(network)) fail(2, `refusing network '${network}': Windows reserves the name; rename its directory`);
  const netfile = `${DEPLOYMENTS}/${network}/network.json`;
  if (!stopOnly && !isFile(netfile)) fail(2, `unknown network '${network}': no ${netfile}`);
  if (!stopOnly) known(target);
  const isLocal = (id) => Array.isArray(project.chains.local) && project.chains.local.includes(id);
  function chainsOf(name) {
    const file = `${DEPLOYMENTS}/${name}/network.json`;
    const net = readJson(file);
    const chainMap = isObject(net) ? net.chains || {} : undefined;
    if (!isObject(chainMap) || !Object.keys(chainMap).every((c) => /^[a-z][a-z0-9]*$/.test(c))) {
      fail(2, `refusing ${name}: a chain's name is not a plain lower-case name`);
    }
    const chains = Object.keys(chainMap);
    if (!chains.length) fail(2, `refusing ${name}: network.json names no chain`);
    // The default chain: sprue.json's chains.default, which the network must have, else its only chain,
    // else none (a step without .on then refuses at plan).
    let home = project.chains.default;
    if (home != null && home !== false && home !== "") {
      home = String(home);
      if (!chainMap[home]) fail(2, `refusing ${name}: network.json has no chain ${home}, which ${PROJECT} names as chains.default`);
    } else home = chains.length === 1 ? chains[0] : "";
    // A chain's rpc is printed into the commands, like the network name, and rehearse passes it to anvil.
    const copy = name === rehearsal || name.startsWith(`${rehearsal}-`);
    for (const c of chains) {
      const rpc = chainMap[c]?.rpc;
      if (typeof rpc !== "string" || !(ALIAS.test(rpc) || (copy && LOOPBACK.test(rpc)))) fail(2, `refusing ${name}: chain ${c}'s rpc is not a plain alias from foundry.toml's [rpc_endpoints]`);
    }
    return { net, chainMap, chains, home };
  }

  // The copy's chains name only the Anvil forks it starts, so forge never sees a real endpoint and holds
  // no key. Reusing an earlier rehearsal would need proof that its forks and inputs still match: it starts over.
  async function rehearse(source) {
    const name = `${rehearsal}-${source}`;
    const dir = `${DEPLOYMENTS}/${name}`;
    if (source === rehearsal || source.startsWith(`${rehearsal}-`)) fail(2, `refusing ${source}: it is a rehearsal network; rehearse the network it copies`);
    if (!ignored(`${dir}/`)) fail(2, `refusing: git does not ignore ${dir}/, where rehearse writes`);
    const recordFile = `${dir}/.sprue/rehearsal.json`;
    const lock = `${dir}/.sprue/lock`;
    const save = (m) => writeFileSync(recordFile, `${JSON.stringify(m, null, 2)}\n`);
    const alive = (pid) => {
      try {
        process.kill(pid, 0);
        return true;
      } catch (e) {
        return e.code === "EPERM";
      }
    };
    const anvilMetadata = (url) => {
      const r = exec("cast", ["rpc", "anvil_metadata", "--rpc-url", url], ["ignore", "pipe", "ignore"]);
      try { return r.status === 0 ? JSON.parse(r.out) : undefined; } catch {}
    };
    if (!existsSync(dir) && stopOnly) fail(2, `no rehearsal of ${source}: no ${dir}`);
    if (existsSync(dir) && !existsSync(dirname(recordFile))) fail(2, `refusing: ${dir} exists and no rehearse staged it; move it away`);
    mkdirSync(dirname(recordFile), { recursive: true });
    // Exclusive, and read under it: two rehearses of one network would share its journals over different
    // forks. A stale lock is not taken over, since two runs could both take it.
    try {
      writeFileSync(lock, String(process.pid), { flag: "wx" });
    } catch (e) {
      if (e.code !== "EEXIST") throw e;
      const pid = Number(readFileSync(lock, "utf8"));
      if (alive(pid)) fail(2, `refusing: a rehearse of ${source} is running, as pid ${pid}`);
      fail(2, `refusing: ${lock} names pid ${pid}, which has exited; remove it if no rehearse of ${source} runs`);
    }
    atExit = () => rmSync(lock, { force: true });
    for (const sig of ["SIGINT", "SIGTERM"]) {
      process.on(sig, () => {
        const done = () => {
          atExit();
          process.exit(130);
        };
        // A step writes its journal until it exits, so the lock is held until then.
        if (forgeStep?.exitCode === null && forgeStep.signalCode === null) {
          forgeStep.once("exit", done);
          forgeStep.kill();
        } else done();
      });
    }
    const previous = readJson(recordFile) ?? { source, forks: [] };
    if (!isObject(previous) || !Array.isArray(previous.forks)) fail(2, `refusing: ${recordFile} is not a rehearse's record; move ${dir} away`);
    // A kept fork's pid may since name another process: signal it only while its URL answers as its instance.
    for (const f of previous.forks) {
      if (anvilMetadata(f.url)?.instanceId !== f.instanceId) continue;
      try { process.kill(f.pid); } catch {}
    }
    if (stopOnly) {
      save({ ...previous, forks: [] });
      out(`stopped the forks of ${name}; its files stay in ${dir}\n`);
      return;
    }

    const { net, chainMap, chains, home } = chainsOf(source);
    const blocksByChain = new Map();
    for (const b of blocks) {
      const m = /^(?:([a-z][a-z0-9]*)=)?([0-9]+)$/.exec(b);
      const chain = m && (m[1] ?? home);
      if (!m || !chainMap[chain]) fail(2, `refusing --block ${b}: name a chain of ${source} as <chain>=<n>`);
      blocksByChain.set(chain, m[2]);
    }
    // One fork per upstream, so chains that name the same endpoint read one state.
    const groups = new Map();
    for (const c of chains) {
      const upstream = chainMap[c].rpc;
      const group = groups.get(upstream) ?? { upstream, id: chainMap[c].id, chains: [] };
      group.chains.push(c);
      if (blocksByChain.has(c)) {
        if (group.block && group.block !== blocksByChain.get(c)) fail(2, `refusing --block: ${group.chains.join(" and ")} share one fork`);
        group.block = blocksByChain.get(c);
      }
      groups.set(upstream, group);
    }
    if (spawnSync("anvil", ["--version"], { stdio: "ignore" }).error) fail(2, "rehearse starts anvil, which is not on PATH: install Foundry");
    // forge signs with a keystore these name even under --unlocked. It loads .env only for names unset,
    // and counts an empty value as set.
    const wallet = ["ETH_KEYSTORE", "ETH_KEYSTORE_ACCOUNT", "ETH_PASSWORD"];
    for (const v of wallet) delete process.env[v];
    const named = isFile(".env") && new RegExp(`^\\s*(export\\s+)?(${wallet.join("|")})\\s*=`, "m").exec(readFileSync(".env", "utf8"));
    if (named) fail(2, `refusing: .env sets ${named[2]}, and forge would sign with that keystore; rehearse holds no key`);
    for (const v of Object.keys(process.env)) if (OVERRIDE.test(v)) delete process.env[v];
    const over = overriding(JSON.parse(must("forge", ["config", "--json"], "refusing: forge config --json failed")), process.env);
    if (over.length) fail(2, `refusing: forge would take ${over.join(", ")} (.env or foundry.toml) over the forks and senders the lines name`);

    // .sprue/ holds the lock.
    for (const f of readdirSync(dir)) if (f !== ".sprue") rmSync(`${dir}/${f}`, RM_TREE);
    const forks = [];
    const record = (kept = forks) => ({ source, forks: kept.map(({ child, ...f }) => f) });
    save(record());
    atExit = () => {
      // ChildProcess.kill signals nothing once the child has exited, so a reused pid is safe.
      // A fork that has not answered yet is not kept: no record could stop it.
      for (const f of forks) if (!keep || !f.instanceId) f.child.kill();
      save(record(keep ? forks.filter((f) => f.instanceId) : []));
      rmSync(lock, { force: true });
      if (keep && forks.every((f) => f.instanceId)) {
        err(`${NAME}: the forks keep running, and ${dir}/network.json names them; stop them with ${NAME} rehearse --stop ${source}\n`);
      }
    };
    for (const f of readdirSync(`${DEPLOYMENTS}/${source}`)) {
      if (isFile(`${DEPLOYMENTS}/${source}/${f}`)) copyFileSync(`${DEPLOYMENTS}/${source}/${f}`, `${dir}/${f}`);
    }
    // Until the forks run, the copy names no endpoint at all.
    for (const c of Object.values(chainMap)) delete c.rpc;
    writeFileSync(`${dir}/network.json`, `${JSON.stringify(net, null, 2)}\n`);
    out(`rehearsal ${name}: staged from ${DEPLOYMENTS}/${source}\n`);

    // Anvil gives every fork Ethereum's code limits; a chain listed in chains.json allows more, and its
    // fork would refuse what the chain takes. Anvil allows init code of twice the limit, as Nitro does.
    const facts = JSON.parse(readFileSync(new URL("./chains.json", import.meta.url), "utf8"));
    for (const group of groups.values()) {
      const limit = facts[String(group.id)]?.codeSizeLimit;
      const log = `${dir}/.sprue/anvil-${forks.length}.log`;
      const fd = openSync(log, "w");
      const args = ["--fork-url", group.upstream, ...(group.block ? ["--fork-block-number", group.block] : [])];
      if (limit) args.push("--code-size-limit", String(limit));
      const child = spawn("anvil", [...args, "--host", "127.0.0.1", "--port", "0", "--auto-impersonate"], { detached: true, stdio: ["ignore", fd, fd], windowsHide: true });
      closeSync(fd);
      child.unref();
      const fork = { chains: group.chains, pid: child.pid, url: "", instanceId: "", child };
      forks.push(fork);
      for (let t = 0; !fork.url; t++) {
        const m = /Listening on ([0-9.]+:[0-9]+)/.exec(readFileSync(log, "utf8"));
        if (m) fork.url = `http://${m[1]}`;
        else if (child.exitCode !== null || t > 1200) fail(1, `anvil did not start for ${group.chains.join(",")} from ${group.upstream}; see ${log}`);
        else await sleep(100);
      }
      const meta = anvilMetadata(fork.url);
      fork.instanceId = meta?.instanceId ?? "";
      save(record());
      const block = meta?.forkedNetwork?.forkBlockNumber;
      out(`fork ${group.chains.join(",")} chain ${chainId(fork.url)}${block == null ? "" : ` block ${block}`}${limit ? ` code limit ${limit}` : ""} ${fork.url} (from alias ${group.upstream})\n`);
      for (const c of group.chains) chainMap[c].rpc = fork.url;
    }
    writeFileSync(`${dir}/network.json`, `${JSON.stringify(net, null, 2)}\n`);
    // A copied check keeps its unit done without reading the fork, so the fork must hold the code it
    // certified: a --block before the deployment would show a contract that is not there as done.
    for (const unit of new Set(exported().nodes.map((n) => n.unit))) {
      const checked = readJson(`${dir}/${unit}.json`)?.checked;
      if (!isObject(checked)) continue;
      for (const [key, hash] of Object.entries(checked)) {
        const role = key.endsWith("CodeHash") ? key.slice(0, -"CodeHash".length) : "";
        if (!/^0x[0-9a-fA-F]{40}$/.test(checked[role]) || typeof hash !== "string") continue;
        const id = String(checked[`${role}ChainId`] ?? checked[`${home}ChainId`]);
        const fork = forks.find((k) => k.chains.some((c) => String(chainMap[c].id) === id));
        if (fork && must("cast", ["codehash", checked[role], "--rpc-url", fork.url]).toLowerCase() !== hash.toLowerCase()) {
          fail(2, `refusing: the fork of ${fork.chains.join(",")} lacks the code ${unit}.json certifies for ${role} at ${checked[role]}; fork a block after its deployment`);
        }
      }
    }
    const dirty = exec("git", ["status", "--porcelain", "--untracked-files=all", "--ignore-submodules=none"]);
    if (dirty.status !== 0 || dirty.out) process.env.DEPLOY_TREE_DIRTY = "1";
    out(`senders are impersonated; no key signs\n`);
    return name;
  }

  if (rehearsing) {
    const name = await rehearse(network);
    if (stopOnly) return 0;
    network = name;
  }
  const { net, chainMap, chains, home } = chainsOf(network);
  // The chain the plan reads, and whose clock a date line without `on` names.
  const planRpc = chainMap[home || chains[0]].rpc;
  // Where a rehearsal network's commands keep forge's records and resume data: never in broadcast/ and
  // cache/, which the real chain of the same id reads. The plan's probes of its steps keep them there too.
  const broadcastDir = network === rehearsal || network.startsWith(`${rehearsal}-`) ? `${DEPLOYMENTS}/${network}/broadcast` : undefined;
  const cacheDir = broadcastDir && `${DEPLOYMENTS}/${network}/cache`;
  const plan = () =>
    graph(GRAPH, "PLAN", "plan(string,string)", [network, target, "--rpc-url", planRpc], broadcastDir ? { FOUNDRY_BROADCAST: broadcastDir, FOUNDRY_CACHE_PATH: cacheDir } : {});
  if (verb === "plan") {
    for (const l of await plan()) out(`${l}\n`);
    return 0;
  }
  const attended = !rehearsing && !(chains.length > 0 && chains.every((c) => isLocal(chainMap[c]?.id)));
  // The sender of steps without .by: DEPLOYER, else the pinned deployer, else the run's own signer
  // (below). A rehearsal has no signer.
  const pin = typeof net.deployer === "string" ? net.deployer : "";
  const unsafeDeployer = process.env.UNSAFE_UNEXPECTED_DEPLOYER === "1";
  const same = (a, b) => a.toLowerCase() === b.toLowerCase();
  const from = process.env.DEPLOYER ? "DEPLOYER" : pin ? "network.json" : "";
  process.env.DEPLOYER ||= pin;
  if (!process.env.DEPLOYER && rehearsing) fail(2, "set DEPLOYER, or network.json's deployer, to the sender of steps without .by");
  if (process.env.DEPLOYER && !/^0x[0-9a-fA-F]{40}$/.test(process.env.DEPLOYER)) fail(2, `${from} names the deployer ${process.env.DEPLOYER}, which is not a 0x address`);
  if (unsafeDeployer && !pin) fail(2, `--unsafe-unexpected-deployer has no use: ${network}'s network.json pins no deployer`);
  if (pin && !same(process.env.DEPLOYER, pin) && !unsafeDeployer) {
    fail(2, `refusing: DEPLOYER is ${process.env.DEPLOYER}, and ${network}'s network.json pins the deployer ${pin}; unset DEPLOYER, or pass --unsafe-unexpected-deployer`);
  }
  if (rehearsing) out(`deployer ${process.env.DEPLOYER}, from ${from}\n`);
  // A sender the run cannot sign for is refused before any send, not at its step's turn. Only a pin
  // falls back to the run's own signer: a DEPLOYER that a person set is never replaced.
  const settleDeployer = (own, canSign, why) => {
    const d = process.env.DEPLOYER || own;
    if (canSign(d)) process.env.DEPLOYER = d;
    else {
      const fallback = from === "network.json" && canSign(own);
      if (unsafeDeployer && fallback) process.env.DEPLOYER = own;
      else fail(2, `refusing: ${from === "DEPLOYER" ? "DEPLOYER is" : `${network}'s network.json pins the deployer`} ${d}, and ${why}; sign as it${fallback && !unsafeDeployer ? `, or pass --unsafe-unexpected-deployer to send as ${own}` : ""}`);
    }
    out(`deployer ${process.env.DEPLOYER}, from ${process.env.DEPLOYER === d ? from || "the signer" : "the signer (--unsafe-unexpected-deployer)"}\n`);
  };
  // git status as the person sees it. Configuration (status.showUntrackedFiles, diff.ignoreSubmodules)
  // must not hide an untracked file or a dirty submodule, and a failing git is a refusal, never an empty
  // status.
  const porcelain = () => {
    const s = must("git", ["status", "--porcelain", "--untracked-files=all", "--ignore-submodules=none"], "refusing: git status failed");
    return s === "" ? [] : s.split("\n");
  };
  const units = new Set(exported().nodes.map((n) => n.unit).filter((u) => typeof u === "string" && u));
  // Local: every chain of the network is listed in sprue.json's chains.local, so a send needs no
  // person. This only picks the signer. `plan`, which precedes every send, refuses a malformed list.
  let anvil = false;
  let signer = [];
  if (rehearsing) {
    anvil = true;
    signer = ["--unlocked"];
  } else if (!attended) {
    // Anvil can send as any address a step names, which need not be the dev key's. Any other node
    // signs with a single key.
    anvil = isAnvil(clientVersion(planRpc));
    signer = anvil ? ["--unlocked"] : ["--private-key", process.env.KEY || DEV_KEY];
    if (wait && anvil) fail(2, "--wait has no use on Anvil: it moves the clock itself");
  }
  // Each endpoint must serve the chain that network.json names. With FOUNDRY_CHAIN_ID set, forge's own
  // chain check reads the variable and not the node, so the preview would show the network's chain for
  // a send to another node.
  const endpoints = [...new Set(chains.map((c) => chainMap[c].rpc))];
  for (const { rpc, id } of Object.values(chainMap)) {
    const got = chainId(rpc);
    if (got !== String(id)) fail(2, `refusing ${network}: ${rpc} is chain ${got}, network.json says ${id}`);
  }
  if (!rehearsing && !attended) {
    const key = must("cast", ["wallet", "address", "--private-key", process.env.KEY || DEV_KEY]);
    // Anvil's --unlocked signs only for the accounts each node lists, impersonated ones included.
    const unlocked = (rpc) => JSON.parse(must("cast", ["rpc", "eth_accounts", "--rpc-url", rpc])).map((a) => a.toLowerCase());
    if (anvil) settleDeployer(key, (d) => endpoints.every((rpc) => unlocked(rpc).includes(d.toLowerCase())), "Anvil signs only for its unlocked accounts");
    else settleDeployer(key, (d) => same(d, key), `this run signs only as ${key}, the address of ${process.env.KEY ? "KEY" : "Anvil's dev key (KEY is unset)"}`);
  }
  let me = "";
  const live = new Set();
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
      const kinds = (await plan()).flatMap((l) => {
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
    // the network's committed journals and records. On one it is required: a real send would be
    // recorded only in a git-ignored directory.
    // A rehearsal's chains.local devnet need not name its client.
    for (const rpc of endpoints) {
      const id = chainId(rpc);
      const v = clientVersion(rpc);
      if (v.status !== 0 && !(broadcastDir && isLocal(Number(id)))) fail(2, `cannot read the node at ${rpc}`);
      const dev = isAnvil(v) || isLocal(Number(id));
      if (dev && !broadcastDir) fail(2, `refusing ${network}: ${rpc} is a development node (${v.out}, chain ${id}); rehearse on a ${rehearsal}-* network`);
      if (!dev && broadcastDir) fail(2, `refusing ${network}: ${rpc} is not a development node (${v.out}, chain ${id}); a rehearsal requires Anvil or a chains.local id`);
    }
    signer = signers[0];
    me = must("cast", ["wallet", "address", ...signer], undefined, ["inherit", "pipe", "inherit"]);
    out(`signer ${me}\n`);
    settleDeployer(me, (d) => same(d, me), `this run signs only as ${me}`);
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
  // journals and metadata the run itself writes (<unit>.json and *.metadata.json).
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
      forgeStep = child;
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
    forgeStep = undefined;
    if (code !== 0) stop(log, code);
  };

  // The transactions of a dry run, from the records its output names. If the output says it has
  // transactions but names no record, they cannot be shown, so refuse.
  const sends = (dry) => {
    const records = dry.text.split("\n").flatMap((l) => (l.startsWith("Transactions saved to: ") ? [l.slice(23).replace(/\r$/, "")] : []));
    if (!records.length && /^SIMULATION COMPLETE/m.test(dry.text)) fail(2, "refusing: the dry run has transactions but names no record to show");
    const show = (v) => (v == null ? "null" : typeof v === "string" ? v : JSON.stringify(v));
    return records.flatMap((f) => {
      try {
        const rec = readJson(f);
        return (rec.deployments ?? [rec]).flatMap(({ chain, transactions }) =>
          transactions.map((t) => {
            const x = t.transaction;
            return {
              text: `chain ${show(chain)} nonce ${show(x.nonce)}: ${show(t.transactionType)} ${t.contractName ?? ""} ${show(t.contractAddress ?? x.to)} value ${show(x.value)} ${t.function ?? ""} ${JSON.stringify(t.arguments ?? [])}`,
              // Gas is left out: forge estimates it again at the send.
              sent: Object.fromEntries(Object.entries({ chain, from: x.from, to: x.to, input: x.input, value: x.value, nonce: x.nonce }).map(([k, v]) => [k, show(v)])),
            };
          }),
        );
      } catch {
        fail(2, `refusing: cannot show the dry run's record ${f}`);
      }
    });
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
    const was = sends(dry);
    for (const { text } of was) out(`  ${text}\n`);
    if (!was.length) out("  no transactions in the dry run\n");
    if (ask(`${line}\nSend this as ${sender}? Type yes: `) !== "yes") fail(6, "not sent: the answer was not yes");
    if (nonces(sender) !== snap) fail(2, "refusing: the sender's nonce moved since before the dry run; run again");
    if (head() !== sha) fail(2, "refusing: HEAD moved since before the dry run; run again");
    if (tree() !== seen) fail(2, "refusing: the working tree changed since before the dry run; run again");
    // Anything else forge reads, a journal or the chain, can change while the question waits: the dry run
    // again must send what was shown.
    const again = forge(cmd.args, cmd.env);
    const now = again.status === 0 ? sends(again) : [];
    const changed = again.status !== 0 ? [`the dry run exits ${again.status}`]
      : now.length !== was.length ? [`now ${now.length} transactions, not ${was.length}`]
      : was.flatMap((w, i) => Object.keys(w.sent).filter((k) => w.sent[k] !== now[i].sent[k]).map((k) => `transaction ${i + 1}'s ${k}`));
    if (changed.length) fail(2, `refusing: what the step would send changed while the question waited (${changed.join(", ")}); run again to see a new preview`);
    const pre = new Set(porcelain());
    await step(cmd);
    // Ownership is by path: the new untracked records under this step's script directory (its chain id
    // is not known here). A concurrent run of the same script is not told apart.
    const script = cmd.args[1].split(":")[0].split("/").pop();
    for (const l of porcelain()) if (l.startsWith(`?? broadcast/${script}/`) && !pre.has(l)) ours.add(l);
  }

  // A date line names its chain's rpc (`# not before <ts> on <rpc> ...`). Without `on`, the plan's.
  const before = (line, at, on) => {
    if (on && !endpoints.includes(on)) fail(2, `refusing: the line reads ${on}, which no chain of ${network} names: ${line}`);
    const clock = on || planRpc;
    const now = must("cast", ["block", "latest", "--field", "timestamp", "--rpc-url", clock]);
    if (!/^[0-9]+$/.test(now)) fail(1, `cannot read the clock at ${clock}`);
    return { late: BigInt(now) < BigInt(at), clock };
  };
  // The journal and its check stay the record; a tag helps people find it.
  const offerTags = () => {
    const git = (...args) => exec("git", args, ["ignore", "pipe", "ignore"]);
    const branch = git("branch", "--show-current").out;
    const remotes = git("remote").out.split("\n").filter(Boolean);
    const tracked = branch ? git("config", "--get", `branch.${branch}.remote`).out : "";
    const remote = remotes.includes(tracked) ? tracked : remotes.length === 1 ? remotes[0] : "";
    const listed = remote ? git("ls-remote", "--tags", remote, `refs/tags/deploy/${network}/*`).out : "";
    const pushed = new Map(listed.split("\n").map((l) => l.split("\t").reverse()));
    const yes = (q) => ask(`${q} Type yes: `) === "yes";
    for (const unit of [...units].sort()) {
      const j = readJson(`${DEPLOYMENTS}/${network}/${unit}.json`);
      if (!isObject(j?.checked)) continue;
      // A tag marks what landed on a live chain, not a test deployment that reads one.
      if (!Object.entries(j.checked).some(([k, v]) => k.endsWith("ChainId") && live.has(String(v)))) continue;
      const tag = `deploy/${network}/${unit}`;
      const ref = `refs/tags/${tag}`;
      // One tag by name: push.followTags would add others.
      const push = `git push --no-follow-tags ${remote || "<remote>"} ${ref}:${ref}`;
      const note = (why) => out(`${tag}: ${why}\n`);
      const dirty = Object.keys(j).filter((k) => k.endsWith("Dirty") && j[k] === true);
      // forge records an abbreviated commit, and a ref of that name would win over it.
      const resolve = (c) => {
        const r = typeof c === "string" && /^[0-9a-f]{7,40}$/.test(c) ? git("rev-parse", "-q", "--verify", `${c}^{commit}`) : undefined;
        return r?.status === 0 && r.out.startsWith(c) ? r.out : "";
      };
      const recorded = [...new Set(Object.keys(j).filter((k) => k.endsWith("Commit")).map((k) => j[k]))];
      const commits = [...new Set(recorded.map(resolve))];
      if (dirty.length) { note(`not tagged: ${dirty.join(", ")} records a dirty tree`); continue; }
      if (commits.length !== 1 || !commits[0]) { note(`not tagged: its roles record ${recorded.join(", ") || "no commit"}, not one commit of this repository`); continue; }
      const tree = (rev) => git("rev-parse", "-q", "--verify", `${rev}^{tree}`).out;
      const local = tree(ref);
      if (!local) {
        if (!yes(`Tag ${tag} at ${commits[0]}, which ${unit}'s journal records?`)) continue;
        const r = spawnSync("git", ["tag", "-a", "-F", "-", tag, commits[0]], {
          input: `${unit} on ${network}, certified by its check. This tag never moves.\n\n${JSON.stringify(j, null, 2)}\n`,
          stdio: ["pipe", "ignore", "inherit"],
        });
        if (r.status !== 0) { note("git tag failed"); continue; }
      } else if (local !== tree(commits[0])) {
        // Squash merges give one tree two commits, so the tree is what must match.
        note(`a tag of another tree exists; tags never move`);
        continue;
      }
      const theirs = pushed.get(ref);
      if (theirs === git("rev-parse", ref).out) continue;
      if (theirs) { note(`${remote} has another tag of that name; it is never overwritten`); continue; }
      if (!remote || !yes(`Push ${tag} to ${remote}?`)) { note(`tagged; push later with ${push}`); continue; }
      // A failed push is no failed deploy: the check already passed. A push without + never replaces a
      // remote tag, so an unreadable remote is offered the push too.
      if (exec("git", ["push", "--no-follow-tags", remote, `${ref}:${ref}`], ["ignore", "ignore", "inherit"]).status !== 0) note(`push failed; retry with ${push}`);
    }
  };
  if (attended && !broadcastDir) {
    atExit = (code) => {
      if (!live.size || ![0, 3, 4].includes(code)) return;
      // The run's status stands whatever the offer meets.
      try { offerTags(); } catch (e) { err(`${NAME}: tags not offered: ${e.message}\n`); }
    };
  }

  const quiet = ["ignore", "ignore", "inherit"];
  let sent = "";
  outer: for (;;) {
    const text = (await plan()).join("\n").replace(/\n+$/, "");
    // git status hides a CRLF checkout of LF files (Git for Windows' core.autocrlf), and solc builds those bytes.
    // After each plan: its forge may have just installed a submodule.
    if (attended && /^i\/(?!crlf)\S*\s+w\/crlf/m.test(must("git", ["ls-files", "--eol", "--recurse-submodules", ":/"], "refusing: git ls-files failed"))) {
      fail(2, "refusing: git checked files out with other line endings than the commit holds (core.autocrlf); run git config --global core.autocrlf false, which applies to all your repositories, then clone the project again");
    }
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
      } else if (line.startsWith("# chain ") || line.startsWith("# done ")) {
        const chain = /^# chain [^ ]+ ([0-9]+) live$/.exec(line);
        if (chain) live.add(chain[1]);
        out(`${line}\n`);
      }
      else if (line.startsWith("#") || (line && !COMMAND.test(line))) fail(2, `unknown plan line: ${line}`);
      else if (line) {
        // A line reaches only the network's own chains, which the checks above read.
        const rpc = / --rpc-url ([^ ]+)/.exec(line)?.[1];
        if (rpc && !endpoints.includes(rpc)) fail(2, `refusing: the line reads ${rpc}, which no chain of ${network} names: ${line}`);
        const cmd = parse(line);
        // The resolved paths: foundry.toml and inherited variables can move them past the line's assignments.
        const result = spawnSync("forge", ["config", "--json"], { encoding: "utf8", stdio: ["ignore", "pipe", "inherit"], env: { ...process.env, ...cmd.env } });
        let config;
        try {
          config = JSON.parse(result.stdout);
        } catch {}
        if (result.status !== 0 || !isObject(config)) fail(2, "refusing: forge config --json failed");
        const over = overriding(config, process.env);
        if (over.length) fail(2, `refusing: forge would take ${over.join(", ")} (the environment, .env or foundry.toml) over the line's --rpc-url or --sender: unset it: ${line}`);
        if (config.broadcast !== (broadcastDir ?? "broadcast")) {
          fail(2, `refusing: forge would keep this run's records in ${config.broadcast}, not ${broadcastDir ?? "broadcast"}; check foundry.toml and FOUNDRY_BROADCAST: ${line}`);
        }
        if (cacheDir && config.cache_path !== cacheDir) {
          fail(2, `refusing: forge would keep this run's resume data in ${config.cache_path}, not ${cacheDir}; check foundry.toml and FOUNDRY_CACHE_PATH: ${line}`);
        }
        sent = text;
        await (attended ? attend(line, cmd) : step(cmd));
      }
    }
    // Judge what the sends left: a plan with nothing to send, even an empty one, ends the run.
    if (!(sent && sent === text)) return 0;
  }
}

// What a rehearse leaves when it ends, however it ends, and the step a signal waits for.
let atExit = () => {};
let forgeStep;

const argv = process.argv.slice(2);
if (argv.length === 1 && (argv[0] === "--version" || argv[0] === "-v")) {
  console.log(JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8")).version);
} else {
  try {
    process.exitCode = await main(argv);
  } catch (e) {
    if (!(e instanceof Exit)) throw e;
    process.exitCode = e.code;
  } finally {
    atExit(process.exitCode);
  }
}

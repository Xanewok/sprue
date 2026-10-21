// The project and graph both views read, and the gate dates they share.
import { readFileSync, readdirSync, statSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { join } from "node:path";

export const read = (f) => { try { return JSON.parse(readFileSync(f, "utf8")); } catch { return undefined; } };

export function loadProject(network) {
  const project = read("sprue.json");
  const graphDir = project.paths.graph.includes("/") ? project.paths.graph.slice(0, project.paths.graph.lastIndexOf("/")) : ".";
  const nodes = read(`${graphDir}/graph.generated.json`).nodes;
  const dir = `${project.paths.deployments}/${network}`;
  const net = read(`${dir}/network.json`) ?? {};
  // The planner's default chain: sprue.json's, or the network's only chain.
  const home = project.chains.default ?? (Object.keys(net.chains ?? {}).length === 1 ? Object.keys(net.chains)[0] : undefined);
  return { project, graphDir, nodes, byId: new Map(nodes.map((n) => [n.id, n])), dir, net, home };
}

// The script that declares a step: the .s.sol file that names its id, else (an id built at run time,
// one step per argument) the unit's script that declares the step's function.
export function scriptsOf({ project, graphDir, nodes }) {
  const scripts = [];
  const walk = (d) => { for (const e of readdirSync(d)) { const p = join(d, e); statSync(p).isDirectory() ? walk(p) : p.endsWith(".s.sol") && scripts.push(p); } };
  walk(project.paths.units);
  if (graphDir !== ".") walk(graphDir);
  const src = new Map(scripts.map((p) => [p, readFileSync(p, "utf8")]));
  const of = new Map();
  for (const n of nodes) {
    const p = scripts.find((p) => src.get(p).includes(`"${n.id}"`))
      ?? scripts.find((p) => p.startsWith(`${project.paths.units}/${n.unit}/`) && new RegExp(`function ${n.signature.replace(/\(.*$/, "")}\\(`).test(src.get(p)));
    if (p) of.set(n.id, p);
  }
  return of;
}

// A gate's date: the plan printed it, an input names it, or (with readViews) its view returns it,
// called through forge on the gate's chain. Each unknown date keeps the reason it is unknown.
export function gateDates({ network, ctx, scriptOf, plans, readViews, log = () => {} }) {
  const { nodes, dir, net, home } = ctx;
  const at = new Map(), why = new Map(), movable = new Set();
  for (const n of nodes) {
    if (n.gate.kind === "none") continue;
    const p = plans.steps.get(n.id);
    if (p?.date) { at.set(n.id, p.date); if (p.movable) movable.add(n.id); continue; }
    if (n.gate.kind === "input") {
      const [unit, key] = n.gate.value.split(".");
      const v = read(`${dir}/${unit}.input.json`)?.[key];
      if (/^[0-9]+$/.test(String(v ?? ""))) at.set(n.id, Number(v));
      else why.set(n.id, `${unit}.input.json names no date for ${key}`);
    } else if (!readViews) why.set(n.id, "its view was not read (--read-gates)");
    else if (!scriptOf.has(n.id)) why.set(n.id, "no script declares this step");
    else {
      const script = scriptOf.get(n.id);
      const args = n.flags?.argument != null ? [network, String(n.flags.argument)] : [network];
      const r = spawnSync("forge", ["script", `${script}:${script.split("/").pop().replace(/\.s\.sol$/, "")}`, "--sig", n.gate.value, ...args, "--rpc-url", net.chains?.[n.on || home]?.rpc], { encoding: "utf8" });
      const m = /== Return ==\s*\n\s*0: uint\d+ ([0-9]+)/.exec(r.stdout ?? "");
      if (m) { at.set(n.id, Number(m[1])); movable.add(n.id); }
      else why.set(n.id, `its view returned no date (${r.status === 0 ? "no return value" : "it reverted or the read failed"}; its contract may not exist yet)`);
      log(`gate ${n.id} ${n.gate.value}: ${m ? new Date(Number(m[1]) * 1000).toISOString() : why.get(n.id)}`);
    }
  }
  return { at, why, movable };
}

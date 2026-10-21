#!/usr/bin/env node
// A runbook of the graph for one network, as a self-contained HTML page: a lane per signing
// role, each step in its dependency order, the date gates marked, and each step's status from `sprue
// plan --json` output (one file per target; see plans.mjs for how they combine).
// usage: node runbook.mjs [--read-gates] <network> <plan.json>... > runbook.html   (at the project root)
import { readPlans } from "./plans.mjs";
import { CSS, PALETTE, STATUSES, conditions, describe, full, shapeKey, slot } from "./marks.mjs";
import { gateDates, loadProject, read, scriptsOf } from "./graph.mjs";

const argv = process.argv.slice(2);
const readViews = argv[0] === "--read-gates" ? !!argv.shift() : false;
const [network, ...planFiles] = argv;
const ctx = loadProject(network);
const { nodes, byId, dir, net } = ctx;

const plans = readPlans(network, planFiles);
const status = new Map([...plans.steps].map(([id, v]) => [id, v.status]));
const why = new Map([...plans.steps].filter(([, v]) => v.why).map(([id, v]) => [id, v.why]));
const gates = gateDates({ network, ctx, scriptOf: scriptsOf(ctx), plans, readViews, log: (l) => process.stderr.write(`${l}\n`) });

// A signing role's address: a step's sender names a value of an input or of network.json, as the
// planner reads it. Steps without one send as the deployer, which network.json may pin.
const value = (ref) => {
  if (!ref) return net.deployer ?? "";
  const [file, key] = ref.split(".");
  const src = file === "network" ? net : read(`${dir}/${file}.input.json`);
  return typeof src?.[key] === "string" ? src[key] : "";
};
const lanes = [...new Set(nodes.map((n) => n.sender))].sort((a, b) => (a === "" ? -1 : b === "" ? 1 : a.localeCompare(b)));
const short = (a) => (/^0x[0-9a-fA-F]{40}$/.test(a) ? `${a.slice(0, 6)}…${a.slice(-4)}` : a);

const gateDate = (n) => gates.at.get(n.id);
const iso = full;
const NOW = Math.floor(Date.now() / 1000);
const laneColor = new Map(lanes.map((l, i) => [l, PALETTE[i % PALETTE.length]]));

// Rank: the longest dependency path, so each step stands right of everything it needs.
const rank = new Map();
const rankOf = (id) => {
  if (rank.has(id)) return rank.get(id);
  rank.set(id, 0);
  const r = Math.max(-1, ...byId.get(id).dependencies.map(rankOf)) + 1;
  rank.set(id, r);
  return r;
};
nodes.forEach((n) => rankOf(n.id));

const W = 168, H = 50, GAP = 14, LANE_PAD = 10, LEFT = 190, TOP = 56;
const slots = new Map(); // lane|rank → count
const pos = new Map();
const laneRows = new Map(lanes.map((l) => [l, 1]));
for (const n of [...nodes].sort((a, b) => rank.get(a.id) - rank.get(b.id))) {
  const k = `${n.sender}|${rank.get(n.id)}`;
  const i = slots.get(k) ?? 0;
  slots.set(k, i + 1);
  laneRows.set(n.sender, Math.max(laneRows.get(n.sender), i + 1));
  pos.set(n.id, { rank: rank.get(n.id), row: i });
}
let y = TOP;
const laneY = new Map();
for (const l of lanes) { laneY.set(l, y); y += laneRows.get(l) * (H + GAP) + LANE_PAD * 2; }
const maxRank = Math.max(...rank.values());
const width = LEFT + (maxRank + 1) * (W + 34) + 20, height = y + 10;
const xy = (id) => {
  const n = byId.get(id), p = pos.get(id);
  return { x: LEFT + p.rank * (W + 34), y: laneY.get(n.sender) + LANE_PAD + p.row * (H + GAP) };
};
const esc = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/"/g, "&quot;");

const svg = [];
lanes.forEach((l, i) => {
  const y0 = laneY.get(l), h = laneRows.get(l) * (H + GAP) + LANE_PAD * 2;
  svg.push(`<rect x="0" y="${y0}" width="${width}" height="${h}" class="lane${i % 2}"/>`);
  const who = l ? value(l) : value("");
  svg.push(`<text x="12" y="${y0 + 22}" class="lanehead">${esc(l || "deployer")}</text>`);
  svg.push(`<text x="12" y="${y0 + 40}" class="lanesub">${esc(who ? short(who) : l ? "no address in its input" : "the signer at run time")}</text>`);
});
for (const n of nodes) for (const d of n.dependencies) {
  const a = xy(d), b = xy(n.id);
  const x1 = a.x + W, y1 = a.y + H / 2, x2 = b.x, y2 = b.y + H / 2, mx = (x1 + x2) / 2;
  svg.push(`<path d="M${x1},${y1} C${mx},${y1} ${mx},${y2} ${x2},${y2}" class="dep"/>`);
}
for (const n of nodes) {
  const { x, y: y0 } = xy(n.id);
  const s = status.get(n.id) ?? "later";
  const cs = conditions(n, { byId, isDone: (d) => status.get(d) === "done", gateAt: gateDate, now: NOW });
  const tip = [n.id, `status: ${s}`, ...describe(cs), gates.why.has(n.id) ? `date unknown: ${gates.why.get(n.id)}` : "", n.on ? `chain: ${n.on}` : "", n.sender ? `signs: ${n.sender}` : "signs: deployer",
    why.get(n.id) ?? "", n.dependencies.length ? `needs: ${n.dependencies.join(", ")}` : ""].filter(Boolean).join("\n");
  svg.push(`<g class="step ${s}"><title>${esc(tip)}</title>`);
  svg.push(`<rect x="${x}" y="${y0}" width="${W}" height="${H}" rx="${n.kind === "predicate" ? 25 : 6}" style="stroke:${laneColor.get(n.sender)}"/>`);
  const [unit, ...rest] = n.id.split(".");
  // The unit name yields to the slot (about 6 px a character at this size).
  const label = `${unit}${n.on ? ` · ${n.on}` : ""}`, room = Math.floor((W - 22 - (cs.length ? slot(cs).length * 6.5 : 0)) / 6);
  svg.push(`<text x="${x + 10}" y="${y0 + 20}" class="unit">${esc(label.length > room ? label.slice(0, Math.max(1, room - 1)) + "…" : label)}</text>`);
  svg.push(`<text x="${x + 10}" y="${y0 + 38}" class="name">${esc(rest.join("."))}</text>`);
  if (cs.length) svg.push(`<text x="${x + W - 8}" y="${y0 + 20}" class="slot" text-anchor="end">${esc(slot(cs))}</text>`);
  svg.push(`</g>`);
}
for (let r = 0; r <= maxRank; r++) svg.push(`<text x="${LEFT + r * (W + 34) + W / 2}" y="34" class="colhead" text-anchor="middle">${r + 1}</text>`);

const counts = {};
for (const n of nodes) { const s = status.get(n.id) ?? "later"; counts[s] = (counts[s] ?? 0) + 1; }
const legend = STATUSES.map(([k, t]) => `<span class="key ${k}"><i></i>${t} <b>${counts[k] ?? 0}</b></span>`).join("") + shapeKey;

process.stdout.write(`<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Deploy Runbook</title>
<style>
:root { --bg:#fbfaf7; --fg:#1d1d1b; --mute:#6b6a64; --lane0:#f4f2ec; --lane1:#fbfaf7; --line:#c9c6bc;
  --done:#2f7d4f; --done-bg:#e3f1e8; --next:#1f5fbf; --next-bg:#e2ecfb; --date:#a86a00; --date-bg:#fbf0dc;
  --queued:#5b4bb7; --queued-bg:#ece9fa; --blocked:#b3261e; --blocked-bg:#f9e3e1; --later:#9b988d; --later-bg:#ffffff; }
@media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) { --bg:#161614; --fg:#ecebe6; --mute:#9d9b93; --lane0:#1d1d1a; --lane1:#161614;
  --line:#45433d; --done:#6fcf97; --done-bg:#1d3326; --next:#7fb0ff; --next-bg:#1b2a44; --date:#f0b453; --date-bg:#3a2c12;
  --queued:#b3a8ff; --queued-bg:#2a2547; --blocked:#ff8a80; --blocked-bg:#44201d; --later:#77756d; --later-bg:#1d1d1a; } }
body { margin:0; background:var(--bg); color:var(--fg); font:14px/1.4 system-ui, -apple-system, sans-serif; }
header { padding:20px 16px 8px; } h1 { font-size:20px; margin:0 0 4px; } p { margin:0; color:var(--mute); }
.legend { display:flex; flex-wrap:wrap; gap:6px 16px; padding:10px 16px; font-size:13px; }
${CSS}
.wrap { overflow-x:auto; padding:0 0 24px; }
svg text { fill:var(--fg); font-family:inherit; }
.lane0 { fill:var(--lane0); } .lane1 { fill:var(--lane1); }
.lanehead { font-weight:600; font-size:13px; } .lanesub, .colhead { fill:var(--mute) !important; font-size:12px; }
.dep { fill:none; stroke:var(--line); stroke-width:1.2; }
.step .unit { font-size:11px; fill:var(--mute); } .step .name { font-size:13px; font-weight:600; }
${STATUSES.map(([k]) => `.${k} rect { fill:var(--${k}-bg); } .key.${k} i { background:var(--${k}-bg); border:1px solid var(--${k}); }`).join("\n")}
</style></head><body>
<header><h1>Deploy runbook: ${esc(network)}</h1>
<p>Each lane is a signing role, with the address its input names; each step stands right of everything it needs. ${plans.from == null ? "No plan given: nothing is shown as done." : `Statuses from plans made ${esc(iso(plans.from))}${plans.to !== plans.from ? ` to ${esc(iso(plans.to))}` : ""}.`} Hover a step for its chain, role, gate and dependencies.</p></header>
<div class="legend">${legend}</div>
<div class="wrap"><svg width="${width}" height="${height}" viewBox="0 0 ${width} ${height}" role="img" aria-label="Deploy runbook">${svg.join("")}</svg></div>
</body></html>
`);

#!/usr/bin/env node
// The graph as a timeline on a real time axis: a branch per set of targets that need the same
// steps (the trunk is what every target needs), each step at the time it ran or may run, and the
// curves where a branch splits off or merges in. Statuses come from `sprue plan --json` output.
// Times: a done step's record (when forge saved it, close to but not when it was mined); a gate's date
// from the plan's `not before`, an input, or, with --read-gates, the gate's view called through forge;
// else as soon as its needs, which is only a lower bound. Empty time between days is compressed.
// usage: node timeline.mjs [--read-gates] <network> <plan.json>... > timeline.html   (at the project root)
import { readPlans } from "./plans.mjs";
import { CSS, PALETTE, STATUSES, conditions, describe, shapeKey, short, slot } from "./marks.mjs";
import { gateDates, loadProject, read, scriptsOf } from "./graph.mjs";

const argv = process.argv.slice(2);
const readGates = argv[0] === "--read-gates" ? !!argv.shift() : false;
const [network, ...planFiles] = argv;
const ctx = loadProject(network);
const { project, nodes, byId, net, home } = ctx;
const chainId = (on) => net.chains?.[on || home]?.id;
const NOW = Math.floor(Date.now() / 1000);

const plans = readPlans(network, planFiles);
const status = new Map([...plans.steps].map(([id, v]) => [id, v.status]));
const why = new Map([...plans.steps].filter(([, v]) => v.why).map(([id, v]) => [id, v.why]));
const stateOf = (n) => status.get(n.id) ?? "later";

const scriptOf = scriptsOf(ctx);

// A done step's time: forge's latest record of its function on its chain. Steps that share a function
// (one per argument) share that file, so none of them takes its time.
const ranAt = new Map();
for (const n of nodes) {
  if (stateOf(n) !== "done" || !scriptOf.has(n.id) || n.flags?.argument != null) continue;
  const fn = n.signature.replace(/\(.*$/, "");
  const rec = read(`broadcast/${scriptOf.get(n.id).split("/").pop()}/${chainId(n.on)}/${fn}-latest.json`);
  if (rec?.timestamp) ranAt.set(n.id, Math.floor(rec.timestamp / (rec.timestamp > 1e11 ? 1000 : 1)));
}

// Each step's CREATEs: forge's record once the step is done, else the rehearsal copy's records, whose
// nonces and addresses are what the next run plans while each signer's nonce stays where it is.
const rehearsalDir = `${project.paths.rehearsal}-${network}`;
const creates = new Map();
for (const n of nodes) {
  if (!scriptOf.has(n.id)) continue;
  const file = `${scriptOf.get(n.id).split("/").pop()}/${chainId(n.on)}/${n.signature.replace(/\(.*$/, "")}-latest.json`;
  const done = stateOf(n) === "done";
  const rec = read(done ? `broadcast/${file}` : `${rehearsalDir}/broadcast/${file}`);
  const cs = (rec?.transactions ?? []).filter((t) => /^CREATE2?$/.test(t.transactionType) && t.contractAddress)
    .map((t) => ({ chain: Number(rec.chain), from: t.transaction?.from, nonce: Number(t.transaction?.nonce), address: t.contractAddress, name: t.contractName, planned: !done }));
  if (cs.length) creates.set(n.id, cs);
}

const { at: gateAt, why: gateWhy, movable } = gateDates({ network, ctx, scriptOf, plans, readViews: readGates, log: (l) => process.stderr.write(`${l}\n`) });

// Times: done steps at their record, else after their needs; open steps at their gate, else as soon
// as their needs (and not before now). A gate whose date is unknown puts the step, and what needs it,
// in the "date unknown" column.
const UNKNOWN = Infinity, UNRECORDED = -1;
// A step after an unmet fact (a predicate not yet done) can run only once the fact holds: its time is
// the earliest it could be, not a date.
const at = new Map(), inferred = new Set(), afterFacts = new Map();
const factsOf = (id) => {
  if (afterFacts.has(id)) return afterFacts.get(id);
  const n = byId.get(id);
  const f = new Set(stateOf(n) === "done" ? [] : n.dependencies.flatMap((d) => [...factsOf(d)]));
  if (n.kind === "predicate" && stateOf(n) !== "done") f.add(id);
  afterFacts.set(id, f);
  return f;
};
const timeOf = (id) => {
  if (at.has(id)) return at.get(id);
  const n = byId.get(id);
  const needs = Math.max(UNRECORDED, ...n.dependencies.map(timeOf));
  let t;
  if (stateOf(n) === "done") { t = ranAt.get(id) ?? needs; if (!ranAt.has(id)) inferred.add(id); }
  else if (n.gate.kind !== "none") t = gateAt.has(id) ? Math.max(gateAt.get(id), needs, NOW) : UNKNOWN;
  else t = Math.max(NOW, needs);
  at.set(id, t);
  return t;
};
nodes.forEach((n) => timeOf(n.id));

// Branches: steps grouped by the set of targets that need them.
const dependents = new Map(nodes.map((n) => [n.id, []]));
for (const n of nodes) for (const d of n.dependencies) dependents.get(d).push(n.id);
const targets = nodes.filter((n) => !dependents.get(n.id).length).map((n) => n.id);
const closure = (t, s = new Set()) => { if (!s.has(t)) { s.add(t); byId.get(t).dependencies.forEach((d) => closure(d, s)); } return s; };
const cl = new Map(targets.map((t) => [t, closure(t)]));
const groupKey = (id) => targets.filter((t) => cl.get(t).has(id)).join(" ");
const groups = new Map();
for (const n of nodes) { const k = groupKey(n.id); if (!groups.has(k)) groups.set(k, []); groups.get(k).push(n.id); }
// Waterfall: lanes in the order of the day their earliest step starts, so the chart reads top-left to
// bottom-right. Lanes that start the same day form a band; inside it a lane follows the lane it splits
// from (the latest-starting lane its steps need), so a branch sits under its parent.
const startOf = (k) => Math.min(...groups.get(k).map((id) => at.get(id)));
const bandOf = (k) => { const t = startOf(k); return t === Infinity ? "~" : t < 0 ? "" : new Date(t * 1000).toISOString().slice(0, 10); };
const parentOf = new Map([...groups.keys()].map((k) => {
  const from = [...new Set(groups.get(k).flatMap((id) => byId.get(id).dependencies).map(groupKey))].filter((g) => g !== k);
  return [k, from.sort((a, b) => startOf(b) - startOf(a) || a.localeCompare(b))[0]];
}));
// The trunk, pinned on top. "root" (the rule): the lane with no parent that the most targets need. "earliest" (for comparison): the lane that starts first, parent or not.
const targetsOf = (k) => k.split(" ").length;
const reachOf = (k) => nodes.filter((n) => groups.get(k).some((id) => closure(n.id).has(id)) && groupKey(n.id) !== k).length;
const RULE = process.env.TIMELINE_TRUNK ?? "root";
const candidates = [...groups.keys()].filter((k) => RULE === "earliest" || !parentOf.get(k));
// Ties go to the root more steps need downstream, then to the earlier start: on a fresh network every
// lane starts now, and the name must never decide.
const rank = (k) => (RULE === "earliest" ? [startOf(k), -targetsOf(k), -reachOf(k)] : [-targetsOf(k), -reachOf(k), startOf(k)]);
const TRUNK = candidates.sort((a, b) => { const [x, y] = [rank(a), rank(b)]; return x[0] - y[0] || x[1] - y[1] || x[2] - y[2] || a.localeCompare(b); })[0];
process.stderr.write(`trunk (${RULE}): ${[...new Set(groups.get(TRUNK).map((id) => byId.get(id).unit))].join(" · ")}\n`);
for (const k of [...groups.keys()].filter((k) => !parentOf.get(k)).sort((a, b) => targetsOf(b) - targetsOf(a))) {
  process.stderr.write(`  root ${[...new Set(groups.get(k).map((id) => byId.get(id).unit))].join(" · ")}: ${targetsOf(k)} targets, ${reachOf(k)} steps downstream, starts ${startOf(k) === -1 ? "unrecorded" : startOf(k) === Infinity ? "unknown" : new Date(startOf(k) * 1000).toISOString().slice(0, 16)}\n`);
}
const order = [TRUNK];
for (const band of [...new Set([...groups.keys()].map(bandOf))].sort()) {
  const left = [...groups.keys()].filter((k) => bandOf(k) === band && k !== TRUNK);
  while (left.length) {
    const ready = left.filter((k) => !left.includes(parentOf.get(k)));
    // A lane with no parent leads; one whose parent starts in a later band follows those placed under theirs.
    const at = (k) => (!parentOf.get(k) ? -1 : order.includes(parentOf.get(k)) ? order.indexOf(parentOf.get(k)) : Infinity);
    const pick = (ready.length ? ready : left).sort((a, b) => at(a) - at(b)
      || startOf(a) - startOf(b) || b.split(" ").length - a.split(" ").length || a.localeCompare(b))[0];
    order.push(pick);
    left.splice(left.indexOf(pick), 1);
  }
}

// X: a column per distinct day (UTC), then the unknown column; inside a day, dependency depth.
// A done step with no record of its own, and nothing recorded before it, has no time: its own column.
const day = (t) => (t === UNKNOWN ? "unknown" : t === UNRECORDED ? "unrecorded" : new Date(t * 1000).toISOString().slice(0, 10));
const days = [...new Set(nodes.map((n) => day(at.get(n.id))))].sort((a, b) => (b === "unrecorded") - (a === "unrecorded") || (a === "unknown") - (b === "unknown") || a.localeCompare(b));
const depth = new Map();
const depthOf = (id) => {
  if (depth.has(id)) return depth.get(id);
  const same = byId.get(id).dependencies.filter((d) => day(at.get(d)) === day(at.get(id)));
  const v = same.length ? Math.max(...same.map(depthOf)) + 1 : 0;
  depth.set(id, v);
  return v;
};
nodes.forEach((n) => depthOf(n.id));
const SW = 172, SH = 46, SGAP = 8, DAYPAD = 26, LEFT = 290, TOP = 70;
const dayWidth = new Map(days.map((d) => [d, (Math.max(...nodes.filter((n) => day(at.get(n.id)) === d).map((n) => depth.get(n.id))) + 1) * (SW + 18) + DAYPAD]));
const dayX = new Map();
let x = LEFT;
for (const d of days) { dayX.set(d, x); x += dayWidth.get(d); }
const width = x + 20;

// Y: a lane per branch; steps that share a lane and a position stack.
const laneH = new Map(), pos = new Map();
for (const k of order) {
  const slot = new Map();
  let rows = 1;
  for (const id of groups.get(k).sort((a, b) => at.get(a) - at.get(b))) {
    const sx = dayX.get(day(at.get(id))) + depth.get(id) * (SW + 18);
    const r = slot.get(sx) ?? 0;
    slot.set(sx, r + 1);
    rows = Math.max(rows, r + 1);
    pos.set(id, { x: sx, row: r });
  }
  laneH.set(k, rows * (SH + SGAP) + 18);
}
const lanesAt = (o) => { const m = new Map(); let y = TOP; for (const k of o) { m.set(k, y); y += laneH.get(k) + 10; } return m; };
// Untangling: the waterfall order is the seed, and only lanes of one band trade places, where that
// lowers the crossings of the split and merge curves (each sampled into 12 segments). Time order between
// bands never yields.
const links = nodes.flatMap((n) => n.dependencies.filter((d) => groupKey(d) !== groupKey(n.id)).map((d) => [d, n.id]));
const curve = (ly, a, b) => {
  const pa = pos.get(a), pb = pos.get(b);
  const x1 = pa.x + SW, y1 = ly.get(groupKey(a)) + 9 + pa.row * (SH + SGAP) + SH / 2, x2 = pb.x, y2 = ly.get(groupKey(b)) + 9 + pb.row * (SH + SGAP) + SH / 2;
  const mx = Math.max(x1 + 20, (x1 + x2) / 2), pts = [];
  for (let i = 0; i <= 12; i++) {
    const t = i / 12, u = 1 - t;
    pts.push([u * u * u * x1 + 3 * u * u * t * mx + 3 * u * t * t * mx + t * t * t * x2, u * u * u * y1 + 3 * u * u * t * y1 + 3 * u * t * t * y2 + t * t * t * y2]);
  }
  return pts;
};
const cross = (p, q, r, s2) => {
  const o = (a, b, c) => Math.sign((b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]));
  return o(p, q, r) * o(p, q, s2) < 0 && o(r, s2, p) * o(r, s2, q) < 0;
};
const score = (o) => {
  const ly = lanesAt(o), cs = links.map(([a, b]) => ({ a, b, pts: curve(ly, a, b) }));
  let n = 0, span = 0;
  for (const c of cs) span += Math.abs(c.pts[0][1] - c.pts[12][1]);
  for (let i = 0; i < cs.length; i++) for (let j = i + 1; j < cs.length; j++) {
    const A = cs[i], B = cs[j];
    if (A.a === B.a || A.b === B.b || A.a === B.b || A.b === B.a) continue;
    let hit = false;
    for (let u = 0; u < 12 && !hit; u++) for (let v = 0; v < 12 && !hit; v++) hit = cross(A.pts[u], A.pts[u + 1], B.pts[v], B.pts[v + 1]);
    if (hit) n++;
  }
  return [n, span];
};
let best = score(order);
const seedCrossings = best[0];
// A lane moves to any position in its own band where that lowers the crossings; the first such move
// is taken and the pass repeats, so the same input always gives the same order.
for (let moved = true, rounds = 0; moved && best[0] > 0 && rounds < 50; rounds++) {
  moved = false;
  for (let i = 0; i < order.length && !moved; i++) for (let j = 0; j < order.length && !moved; j++) {
    // The trunk keeps the top, and nothing moves above it.
    const trunk = (k) => k === TRUNK;
    if (i === j || bandOf(order[i]) !== bandOf(order[j]) || trunk(order[i])) continue;
    if (j < i && order.slice(j, i).some(trunk)) continue;
    const t = [...order];
    const [k] = t.splice(i, 1);
    t.splice(j, 0, k);
    const s2 = score(t);
    if (s2[0] < best[0]) { best = s2; order.splice(0, order.length, ...t); moved = true; }
  }
}
process.stderr.write(`lanes: ${seedCrossings} crossings in the seed order, ${best[0]} after untangling\n`);
const laneY = lanesAt(order);
const height = [...laneY.values()].reduce((m, y) => Math.max(m, y), 0) + Math.max(...laneH.values()) + 20;
const xy = (id) => { const p = pos.get(id); return { x: p.x, y: laneY.get(groupKey(id)) + 9 + p.row * (SH + SGAP) }; };
const esc = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/"/g, "&quot;");
const color = new Map(order.map((k, i) => [k, PALETTE[i % PALETTE.length]]));
const iso = (t) => new Date(t * 1000).toISOString().slice(0, 16).replace("T", " ") + "Z";
// A row is titled by what it holds: its units in time order. Rows of the same units add their first
// and last step. The second line says who needs the row; the hover lists the targets.
const stepsOf = (k) => groups.get(k).slice().sort((a, b) => at.get(a) - at.get(b) || depth.get(a) - depth.get(b));
const unitsOf = (k) => [...new Set(stepsOf(k).map((id) => byId.get(id).unit))].join(" · ");
const title = (k) => {
  const ids = stepsOf(k), fn = (id) => id.slice(byId.get(id).unit.length + 1);
  const twin = order.some((o) => o !== k && unitsOf(o) === unitsOf(k));
  return twin ? `${unitsOf(k)}: ${fn(ids[0])}${ids.length > 1 ? ` … ${fn(ids.at(-1))}` : ""}` : unitsOf(k);
};
const neededBy = (k) => {
  const ts = k.split(" ");
  return ts.length === targets.length ? "needed by every target" : ts.length > 1 ? `needed by ${ts.length} targets` : `ends at ${ts[0]}`;
};

const svg = [];
// Day columns, with a break mark where days are skipped.
let prev = null;
for (const d of days) {
  const x0 = dayX.get(d);
  svg.push(`<line x1="${x0 - 8}" y1="${TOP - 30}" x2="${x0 - 8}" y2="${height}" class="${d === "unknown" ? "unknowncol" : "daycol"}"/>`);
  svg.push(`<text x="${x0}" y="${TOP - 40}" class="dayhead">${d === "unknown" ? "date unknown" : d === "unrecorded" ? `done by ${plans.to ? short(plans.to) : "?"}, time not recorded` : d}</text>`);
  if (prev && prev !== "unrecorded" && d !== "unknown" && (Date.parse(d) - Date.parse(prev)) / 864e5 > 1) {
    const gap = Math.round((Date.parse(d) - Date.parse(prev)) / 864e5) - 1;
    svg.push(`<text x="${x0 - 8}" y="${TOP - 18}" class="gap" text-anchor="middle">≈ ${gap} d</text>`);
  }
  prev = d;
}
const nowDay = day(NOW);
if (dayX.has(nowDay)) svg.push(`<line x1="${dayX.get(nowDay) - 4}" y1="${TOP - 30}" x2="${dayX.get(nowDay) - 4}" y2="${height}" class="now"/><text x="${dayX.get(nowDay) + 2}" y="${TOP - 4}" class="nowlabel">now</text>`);
// Lanes and their tracks.
for (const k of order) {
  const ids = groups.get(k), c = color.get(k), y0 = laneY.get(k);
  const xs = ids.map((id) => xy(id).x);
  svg.push(`<text x="12" y="${y0 + 22}" class="lanehead" style="fill:${c}">${esc(title(k))}</text>`);
  svg.push(`<text x="12" y="${y0 + 38}" class="lanesub"><title>${esc(`needed by:\n${k.split(" ").join("\n")}`)}</title>${esc(`${neededBy(k)} · ${ids.length} step${ids.length > 1 ? "s" : ""}`)}</text>`);
  svg.push(`<line x1="${Math.min(...xs)}" y1="${y0 + 9 + SH / 2}" x2="${Math.max(...xs) + SW}" y2="${y0 + 9 + SH / 2}" stroke="${c}" class="track"/>`);
}
// Needs inside a branch: thin, since steps of one branch need not form a sequence.
for (const n of nodes) for (const d of n.dependencies) {
  if (groupKey(d) !== groupKey(n.id)) continue;
  const a = xy(d), b = xy(n.id), x1 = a.x + SW, y1 = a.y + SH / 2, x2 = b.x, y2 = b.y + SH / 2, mx = Math.max(x1 + 6, (x1 + x2) / 2);
  svg.push(`<path d="M${x1},${y1} C${mx},${y1} ${mx},${y2} ${x2},${y2}" class="inner"/>`);
}
// Splits and merges: a need from another branch.
for (const n of nodes) for (const d of n.dependencies) {
  if (groupKey(d) === groupKey(n.id)) continue;
  const a = xy(d), b = xy(n.id), c = color.get(groupKey(n.id));
  const x1 = a.x + SW, y1 = a.y + SH / 2, x2 = b.x, y2 = b.y + SH / 2, mx = Math.max(x1 + 20, (x1 + x2) / 2);
  svg.push(`<path d="M${x1},${y1} C${mx},${y1} ${mx},${y2} ${x2},${y2}" stroke="${c}" class="link"/>`);
}
for (const n of nodes) {
  const { x: x0, y: y0 } = xy(n.id), s = stateOf(n), t = at.get(n.id), c = color.get(groupKey(n.id));
  const facts = [...factsOf(n.id)].filter((f) => f !== n.id);
  const g = gateAt.get(n.id);
  const gate = n.gate.kind === "none" ? "" : g ? `gate ${n.gate.value} at ${iso(g)}${g <= NOW ? " (reached)" : movable.has(n.id) ? " (may still move)" : ""}` : `gate ${n.gate.value}: date unknown, ${gateWhy.get(n.id) ?? "not read"}`;
  const when = s === "done"
    ? t === UNRECORDED || inferred.has(n.id) ? `done at some time ${t === UNRECORDED ? "" : `after ${iso(t)} and `}by ${iso(plans.steps.get(n.id)?.planned ?? plans.to)} (no record of its own)` : `recorded ${iso(t)} (forge's record, saved after the send)`
    : t === UNKNOWN ? "" : `${facts.length ? `at the earliest ${iso(t)}, once ${facts.join(", ")} hold${facts.length > 1 ? "" : "s"}` : `can run from ${iso(t)}`}`;
  const cs = conditions(n, { byId, isDone: (d) => stateOf(byId.get(d)) === "done", gateAt: (m) => gateAt.get(m.id), now: NOW });
  const tip = [n.id, `status: ${s}`, gate, when, ...describe(cs).filter((l) => !l.includes(n.gate.value) || n.gate.kind === "none"), n.on ? `chain: ${n.on}` : "", `signs: ${n.sender || "deployer"}`, why.get(n.id) ?? "", n.dependencies.length ? `needs: ${n.dependencies.join(", ")}` : ""].filter(Boolean).join("\n");
  const [unit, ...rest] = n.id.split(".");
  svg.push(`<g class="step ${s}" data-step="${esc(n.id)}"><title>${esc(tip)}</title><rect x="${x0}" y="${y0}" width="${SW}" height="${SH}" rx="${n.kind === "predicate" ? 17 : 5}" style="--c:${c}"/>`);
  // Top right: the node's own conditions, and an unmet fact its own pending mark. When a done node
  // happened has no record, its bounds are in the hover: on boxes they would all repeat the plan's time.
  const mark = slot(cs) || (n.kind === "predicate" && s !== "done" ? "⧗" : "");
  if (mark) svg.push(`<text x="${x0 + SW - 6}" y="${y0 + 14}" class="slot" text-anchor="end">${esc(mark)}</text>`);
  // The unit name yields to the slot (about 6 px a character at this size).
  const room = Math.floor((SW - 18 - mark.length * 6.5) / 5.6);
  svg.push(`<text x="${x0 + 8}" y="${y0 + 14}" class="unit">${esc(unit.length > room ? unit.slice(0, Math.max(1, room - 1)) + "…" : unit)}</text>`);
  svg.push(`<text x="${x0 + 8}" y="${y0 + 28}" class="name">${esc(rest.join("."))}</text>`);
  const made = creates.get(n.id);
  if (made) svg.push(`<text x="${x0 + 8}" y="${y0 + 41}" class="live">${esc(`${made[0].planned ? "plans" : "made"} ${made[0].name ?? "?"} at nonce ${made[0].nonce}${made.length > 1 ? ` +${made.length - 1}` : ""}`)}</text>`);
  svg.push(`</g>`);
}

const legend = STATUSES.map(([k, t]) => `<span class="key ${k}"><i></i>${t}</span>`).join("") + shapeKey;
process.stdout.write(`<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Deploy Timeline</title>
<style>
:root { --ok:#2f7d4f; --warn:#a86a00; --bad:#b3261e; --bad-bg:#f9e3e1; --bg:#fbfaf7; --fg:#1d1d1b; --mute:#6b6a64; --grid:#e4e1d8; --now:#b3261e; --card:#ffffff;
  --done:#e3f1e8; --next:#e2ecfb; --date:#fbf0dc; --queued:#ece9fa; --blocked:#f9e3e1; --fact:#ffffff; --later:#ffffff; }
@media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) { --ok:#6fcf97; --warn:#f0b453; --bad:#ff8a80; --bad-bg:#44201d; --bg:#161614; --fg:#ecebe6; --mute:#9d9b93; --grid:#2c2b27; --now:#ff8a80; --card:#1d1d1a;
  --done:#1d3326; --next:#1b2a44; --date:#3a2c12; --queued:#2a2547; --blocked:#44201d; --fact:#1d1d1a; --later:#1d1d1a; } }
body { margin:0; background:var(--bg); color:var(--fg); font:14px/1.4 system-ui, -apple-system, sans-serif; }
header { padding:20px 16px 4px; } h1 { font-size:20px; margin:0 0 4px; } p { margin:0; color:var(--mute); max-width:900px; }
.legend { display:flex; flex-wrap:wrap; gap:6px 16px; padding:10px 16px; font-size:13px; }
${CSS}
${STATUSES.map(([k]) => `.key.${k} i { background:var(--${k}); border:1px solid var(--mute); } .step.${k} rect { fill:var(--${k}); }`).join("\n")}
.wrap { overflow-x:auto; padding-bottom:24px; }
svg text { fill:var(--fg); font-family:inherit; }
.daycol { stroke:var(--grid); } .unknowncol { stroke:var(--mute); stroke-dasharray:4 4; }
.dayhead { font-size:12px; font-weight:600; } .gap { font-size:11px; fill:var(--mute) !important; }
.now { stroke:var(--now); stroke-width:1.5; stroke-dasharray:6 3; } .nowlabel { fill:var(--now) !important; font-size:11px; font-weight:600; }
.lanehead { font-weight:700; font-size:13px; } .lanesub { fill:var(--mute) !important; font-size:12px; }
.track { stroke-width:6; stroke-linecap:round; opacity:.28; } .inner { fill:none; stroke:var(--mute); stroke-width:1; opacity:.5; } .link { fill:none; stroke-width:2; opacity:.7; }
.step rect { stroke:var(--c); }
.step .unit { font-size:10.5px; fill:var(--mute); } .step .gate { font-size:11px; font-weight:600; fill:var(--fg); } .step .name { font-size:12.5px; font-weight:600; }
.step .live { font-size:10.5px; fill:var(--mute); } .step .live.ok { fill:var(--ok) !important; } .step .live.warn { fill:var(--warn) !important; }
.step .live.bad { fill:var(--bad) !important; font-weight:700; } .step.moved rect { stroke:var(--bad) !important; stroke-width:3; stroke-dasharray:none; }
.livebar { display:flex; flex-wrap:wrap; align-items:center; gap:8px 14px; padding:8px 16px; font-size:13px; border-top:1px solid var(--grid); border-bottom:1px solid var(--grid); }
.livebar input { width:240px; font:inherit; font-size:12px; padding:3px 6px; background:var(--card); color:var(--fg); border:1px solid var(--grid); border-radius:4px; }
.livebar button { font:inherit; font-size:13px; padding:2px 10px; border:1px solid var(--grid); border-radius:4px; background:var(--card); color:var(--fg); cursor:pointer; }
#banner { display:none; margin:8px 16px 0; padding:8px 12px; border-radius:6px; background:var(--bad-bg); color:var(--bad); font-weight:600; }
#status { color:var(--mute); }
</style></head><body>
<header><h1>Deploy timeline: ${esc(network)}</h1>
<p>Each row is a branch: the steps that exactly the same targets need, titled by their units; its second line says which targets need it. Curves show where a branch splits off or merges in. Steps stand at the day they were recorded or may run; empty days are compressed. ${plans.from == null ? "No plan given: nothing is shown as done." : `Statuses from plans made ${esc(iso(plans.from))}${plans.to !== plans.from ? ` to ${esc(iso(plans.to))}` : ""}.`} Hover a step for its time, gate, signer and needs.</p></header>
<div class="legend">${legend}</div>
<div class="livebar"><b>Live chain facts</b>${Object.entries(net.chains ?? {}).map(([name, c]) => `<label>${esc(name)} <input data-chain="${c.id}" placeholder="RPC URL for chain ${c.id}, or wallet"></label>`).join("")}<button id="refresh" title="Read the chains again">↻</button><span id="status">enter an RPC URL (kept in this browser only) or "wallet"</span></div>
<div id="banner"></div>
<div class="wrap"><svg width="${width}" height="${height}" viewBox="0 0 ${width} ${height}" role="img" aria-label="Deploy timeline">${svg.join("")}</svg></div>
<script>
const LIVE = ${JSON.stringify({ creates: Object.fromEntries(creates) })};
const store = { get: (k) => { try { return localStorage.getItem(k); } catch { return null; } }, set: (k, v) => { try { localStorage.setItem(k, v); } catch {} } };
const inputs = [...document.querySelectorAll("input[data-chain]")];
// #rpc.<chainId>=<url> in the address overrides what this browser remembers, for tools and links.
const hash = new URLSearchParams(location.hash.slice(1));
for (const i of inputs) { i.value = hash.get("rpc." + i.dataset.chain) ?? store.get("rpc." + i.dataset.chain) ?? ""; i.onchange = () => { store.set("rpc." + i.dataset.chain, i.value.trim()); refresh(); }; }
const short = (a) => a.slice(0, 6) + "…" + a.slice(-4);
async function call(chain, url, calls) {
  if (url === "wallet") {
    if (!window.ethereum) throw new Error("no wallet in this browser");
    const id = Number(await ethereum.request({ method: "eth_chainId" }));
    if (id !== chain) throw new Error("the wallet is on chain " + id);
    return Promise.all(calls.map(([method, params]) => ethereum.request({ method, params })));
  }
  const r = await fetch(url, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(calls.map(([method, params], id) => ({ jsonrpc: "2.0", id, method, params }))) });
  const out = await r.json();
  return calls.map((_, i) => { const x = out.find((o) => o.id === i); if (!x || x.error) throw new Error(x?.error?.message ?? "no answer"); return x.result; });
}
async function refresh() {
  const lines = [], moved = [];
  for (const i of inputs) {
    const chain = Number(i.dataset.chain), url = i.value.trim();
    if (!url) continue;
    const mine = Object.entries(LIVE.creates).flatMap(([step, cs]) => cs.filter((c) => c.chain === chain).map((c) => ({ step, ...c })));
    const senders = [...new Set(mine.map((c) => c.from.toLowerCase()))];
    try {
      const res = await call(chain, url, [["eth_getBlockByNumber", ["latest", false]], ...senders.map((a) => ["eth_getTransactionCount", [a, "latest"]]), ...mine.map((c) => ["eth_getCode", [c.address, "latest"]])]);
      const head = res[0], nonce = Object.fromEntries(senders.map((a, k) => [a, Number(res[1 + k])]));
      lines.push(i.closest("label").firstChild.textContent.trim() + " block " + Number(head.number).toLocaleString() + ", " + Math.round(Date.now() / 1000 - Number(head.timestamp)) + " s ago");
      mine.forEach((c, k) => {
        const code = res[1 + senders.length + k] !== "0x", now = nonce[c.from.toLowerCase()];
        const g = document.querySelector('g[data-step="' + c.step + '"]'), t = g?.querySelector(".live");
        if (!t || t.dataset.done) return;
        let text, cls = "ok";
        if (!c.planned) { text = code ? "✓ code at " + short(c.address) : "✗ no code at " + short(c.address); if (!code) cls = "bad"; }
        else if (code) { text = "✗ code already at " + short(c.address); cls = "bad"; }
        else if (now === c.nonce) text = "✓ nonce " + c.nonce + " → " + short(c.address);
        else if (now > c.nonce) { text = "✗ nonce " + c.nonce + ", now " + now; cls = "bad"; }
        else { text = "nonce " + c.nonce + ", now " + now + " (" + (c.nonce - now) + " first)"; cls = "warn"; }
        t.textContent = text; t.setAttribute("class", "live " + cls); t.dataset.done = "1";
        g.classList.toggle("moved", cls === "bad");
        if (cls === "bad") moved.push(c.step);
      });
    } catch (e) { lines.push("chain " + chain + ": " + e.message); }
  }
  document.querySelectorAll(".live[data-done]").forEach((t) => delete t.dataset.done);
  document.getElementById("status").textContent = lines.length ? "read " + new Date().toLocaleTimeString() + ": " + lines.join(" · ") : 'enter an RPC URL (kept in this browser only) or "wallet"';
  const b = document.getElementById("banner");
  b.style.display = moved.length ? "block" : "none";
  b.textContent = "The chain moved past this plan at " + [...new Set(moved)].join(", ") + ": regenerate the plan before any send.";
}
document.getElementById("refresh").onclick = refresh;
refresh();
setInterval(() => { if (!document.hidden) refresh(); }, 15000);
</script>
</body></html>
`);

// What both views draw the same way. A box's fill is its status and its outline its group; a dashed
// outline is a node not done yet; a pill is a fact (a predicate), a rectangle a step. Its top-right
// slot lists the conditions it waits on as (kind, state) pairs, in text glyphs so that no font turns
// them into coloured emoji.
export const CLOCK = "⏱︎", FACT = "◇", PENDING = "⧗", SETTLED = "✓", UNKNOWN = "?";
export const STATUSES = [["done", "done"], ["next", "next: the plan sends it now"], ["date", "waits for its date"], ["queued", "after the next sends"], ["blocked", "cannot reach yet"], ["later", "later"]];
// No red: red means a problem.
export const PALETTE = ["#3b6fd6", "#2e8b57", "#7b4fd6", "#00838f", "#8d6e00", "#4f7a28", "#5d4037", "#1565c0", "#00695c", "#6a1b9a", "#d17a00", "#455a64", "#3949ab", "#558b2f", "#0277bd", "#795548"];
export const short = (t) => new Date(t * 1000).toISOString().slice(5, 16).replace("T", " ");
export const full = (t) => new Date(t * 1000).toISOString().slice(0, 16).replace("T", " ") + "Z";

// A node's own conditions: its date gate, and the facts it needs directly. Facts further upstream
// show on their own pills.
export function conditions(n, { byId, isDone, gateAt, now }) {
  const out = [];
  if (n.gate.kind !== "none") {
    const g = gateAt(n);
    out.push({ icon: CLOCK, label: g == null ? "" : short(g), state: g == null ? UNKNOWN : g <= now ? SETTLED : PENDING, about: `${n.gate.value}${g == null ? "" : ` at ${full(g)}`}` });
  }
  for (const d of n.dependencies) {
    const p = byId.get(d);
    if (p.kind === "predicate") out.push({ icon: FACT, label: d.slice(p.unit.length + 1), state: isDone(d) ? SETTLED : PENDING, about: d });
  }
  return out;
}
// One condition keeps its label; several show only their icons (the hover names them).
export const slot = (cs) => (cs.length === 1 ? [cs[0].icon, cs[0].label, cs[0].state].filter(Boolean).join(" ") : cs.map((c) => c.icon + c.state).join(" "));
export const describe = (cs) => cs.map((c) => `${c.state === SETTLED ? "met" : c.state === UNKNOWN ? "date unknown" : "waiting"}: ${c.about}`);

export const CSS = `
.step rect { stroke-width:1.8; } .step:not(.done) rect { stroke-dasharray:5 3; }
.step .slot { font-size:11px; font-weight:600; fill:var(--fg); }
.legend .key i { display:inline-block; width:20px; height:10px; border-radius:2px; margin-right:6px; vertical-align:0; }
.legend .shape { color:var(--mute); }`;
export const shapeKey = `<span class="shape">▭ step · ◯ fact (pill) · dashed: not done · ${CLOCK} date, ${FACT} fact: ${PENDING} pending, ${SETTLED} met, ${UNKNOWN} unknown</span>`;

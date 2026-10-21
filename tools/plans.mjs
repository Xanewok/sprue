// The status of each step from `sprue plan --json` files of one network. Each plan is read in its own
// order, as `run` reads it: a date line holds its step, a refused step's command does not make it
// next, and nothing after `then plan again` is judged. Across plans, the newest plan that names a
// step decides it, so an old plan's "done" never outlives a newer observation.
import { readFileSync } from "node:fs";

export function readPlans(network, files) {
  const plans = files.map((f) => {
    const p = JSON.parse(readFileSync(f, "utf8"));
    if (p.network !== network) throw new Error(`${f} is a plan of ${p.network}, not ${network}`);
    if (!Number.isInteger(p.planned)) throw new Error(`${f} does not say when it was planned; make it again with sprue plan --json`);
    return { file: f, ...p };
  }).sort((a, b) => a.planned - b.planned);
  const steps = new Map(); // id → { status, why, date, movable, planned }
  for (const p of plans) {
    const seen = new Map();
    const set = (id, v) => seen.set(id, { ...seen.get(id), ...v });
    for (const l of p.lines) {
      if (l.type === "done") set(l.step, { status: "done" });
      else if (l.type === "not-before") set(l.step, { status: "date", date: Number(l.time), movable: l.movable });
      else if (l.type === "cannot-reach") set(l.step, { status: "blocked", why: l.reason });
      else if (l.type === "send" && l.step && !seen.get(l.step)?.status) set(l.step, { status: "next" });
      else if (l.type === "then-plan-again" && !seen.get(l.step)?.status) set(l.step, { status: "queued" });
    }
    for (const [id, v] of seen) steps.set(id, { ...v, planned: p.planned });
  }
  // With no plan, nothing is known done: the graph as a fresh network would see it.
  const times = plans.map((p) => p.planned);
  return { steps, from: times.length ? Math.min(...times) : null, to: times.length ? Math.max(...times) : null };
}

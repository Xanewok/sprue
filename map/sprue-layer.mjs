// SPDX-License-Identifier: MIT
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';

import { ADDR, lc } from './abi.mjs';

export function sprueLayer({ dir, network }, out, nodes, edges, warnings) {
  const jdir = join(dir, 'deployments', network);
  if (!existsSync(jdir)) {
    warnings.push(`no journals at deployments/${network}`);
    return null;
  }
  let netIds = [];
  try {
    netIds = Object.values(JSON.parse(readFileSync(join(jdir, 'network.json'), 'utf8')).chains || {}).map((c) => Number(c.id));
  } catch {}
  const unitOfHash = new Map();
  for (const f of readdirSync(jdir).sort()) {
    if (!f.endsWith('.json') || f === 'network.json' || /\.(input|metadata)\.json$/.test(f)) continue;
    let j;
    try { j = JSON.parse(readFileSync(join(jdir, f), 'utf8')); } catch { continue; }
    const unit = f.slice(0, -5);
    const ids = Object.entries(j).filter(([k, v]) => /ChainId$/.test(k) && typeof v === 'number').map(([, v]) => v);
    const chains = ids.length ? ids : netIds;
    const checked = j.checked || {};
    for (const [k, v] of Object.entries(j)) {
      if (typeof v !== 'string' || !ADDR.test(v) || !(k + 'Tx' in j || k + 'CodeHash' in j || k in checked)) continue;
      if (j[k + 'Tx']) unitOfHash.set(lc(j[k + 'Tx']), unit);
      for (const c of chains) {
        const n = nodes.get(`${c}:${lc(v)}`);
        if (!n) continue;
        n.role = k === unit ? k : `${unit}.${k}`;
        if (lc(checked[k]) !== lc(v)) continue;
        n.certified = true;
        // A certified role's constructor arguments and certificate entries are what its check authenticated.
        const vouched = new Set(Object.values(checked).filter((x) => typeof x === 'string' && ADDR.test(x)).map(lc));
        const argWords = String(j[k + 'Args'] || '').replace(/^0x/, '').match(/.{64}/g) || [];
        for (const w of argWords) if (/^0{24}/.test(w)) vouched.add('0x' + w.slice(24).toLowerCase());
        for (const e of edges.values())
          if (e.from === n.id && (e.kind === 'deploy' || e.names?.some((m) => m.kind === 'deploy')) && vouched.has(e.to.split(':')[1])) e.verified = true;
      }
    }
  }
  // Step ids: a record's script maps to the unit whose journal names one of its transactions.
  const scriptUnit = new Map();
  for (const x of out) if (x.hash && unitOfHash.has(lc(x.hash))) scriptUnit.set(x.script, unitOfHash.get(lc(x.hash)));
  let graph = null;
  try {
    const cfg = JSON.parse(readFileSync(join(dir, 'sprue.json'), 'utf8'));
    graph = JSON.parse(readFileSync(join(dir, dirname(cfg.paths.graph), 'graph.generated.json'), 'utf8')).nodes;
  } catch {}
  const ids = new Map();
  for (const x of out) {
    const unit = scriptUnit.get(x.script);
    if (!unit || !x.sig) continue;
    const id = graph ? graph.find((g) => g.unit === unit && g.signature.startsWith(x.sig + '('))?.id : `${unit}.${x.sig}`;
    if (id) ids.set(x.i, id);
  }
  return ids;
}

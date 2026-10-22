// SPDX-License-Identifier: MIT
// What sprue's journals add to a map built from forge's records alone: role names, certified roles, links whose
// constructor arguments a certificate vouches for, and a plan step id for each transaction a journal unit and a script
// signature identify.
//
// Guarantees: it only adds `role` and `certified` to nodes, `verified` to edges, and returns step ids; the map's
// nodes, links and transactions are the records' either way. A journal address names a node only on the chains
// that journal belongs to.
// Relies on the journal layout `<unit>.json`: an address field `k` is a role when `kTx`, `kCodeHash` or a
// `checked.k` entry accompanies it, and `checked.k` equal to the address is the unit's own certificate of it.
// An unreadable journal or `network.json` is skipped, not reported.

import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';

import { ADDR, lc } from './abi.mjs';

// Returns a map of transaction index to step id, or null (with a warning) when the network has no journal directory.
export function sprueLayer({ dir, network }, out, nodes, edges, warnings) {
  const jdir = join(dir, network);
  if (!existsSync(jdir)) {
    warnings.push(`no journals at ${jdir}`);
    return null;
  }

  let netIds = [];
  try {
    const net = JSON.parse(readFileSync(join(jdir, 'network.json'), 'utf8'));
    netIds = Object.values(net.chains || {}).map((c) => Number(c.id));
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

      for (const c of chains) {
        if (j[k + 'Tx']) unitOfHash.set(`${c}:${lc(j[k + 'Tx'])}`, unit);
        const n = nodes.get(`${c}:${lc(v)}`);
        if (!n) continue;
        n.role = k === unit ? k : `${unit}.${k}`;
        if (lc(checked[k]) !== lc(v)) continue;
        n.certified = true;
        verifyLinks(n, edges, checked, j[k + 'Args']);
      }
    }
  }

  // A record's script maps to the unit whose journal names one of its transactions.
  const scriptUnit = new Map();
  for (const x of out) {
    const hashKey = `${x.chain}:${lc(x.hash)}`;
    if (x.hash && unitOfHash.has(hashKey)) scriptUnit.set(`${x.chain}:${x.script}`, unitOfHash.get(hashKey));
  }

  let graph = null;
  try {
    const cfg = JSON.parse(readFileSync(join(dir, 'sprue.json'), 'utf8'));
    graph = JSON.parse(readFileSync(join(dir, dirname(cfg.paths.graph), 'graph.generated.json'), 'utf8')).nodes;
  } catch {}

  const ids = new Map();
  for (const x of out) {
    const unit = scriptUnit.get(`${x.chain}:${x.script}`);
    if (!unit || !x.sig) continue;
    const id = graph
      ? graph.find((g) => g.unit === unit && g.signature.startsWith(x.sig + '('))?.id
      : `${unit}.${x.sig}`;
    if (id) ids.set(x.i, id);
  }
  return ids;
}

// A certified role's constructor arguments and certificate entries are what its check authenticated, so a deploy
// link from it to one of those addresses is verified.
function verifyLinks(n, edges, checked, args) {
  const vouched = new Set(Object.values(checked).filter((x) => typeof x === 'string' && ADDR.test(x)).map(lc));
  const argWords = String(args || '').replace(/^0x/, '').match(/.{64}/g) || [];
  for (const w of argWords) if (/^0{24}/.test(w)) vouched.add('0x' + w.slice(24).toLowerCase());

  for (const e of edges.values()) {
    if (e.from !== n.id) continue;
    const deploys = e.kind === 'deploy' || e.names?.some((m) => m.kind === 'deploy');
    if (deploys && vouched.has(e.to.split(':')[1])) e.verified = true;
  }
}

// SPDX-License-Identifier: MIT
// What forge recorded: broadcast records read into one ordered list of transactions with their receipts, and the
// project's compiled ABIs from `out/`.
//
// Guarantees: `mergeTransactions` returns each transaction that has a hash once per chain, and the mined transactions
// of one chain in (blockNumber, transactionIndex) order, whatever record file holds them; other chains keep their
// place, and so do unmined ones unless a mined transaction of the same sender and nonce replaces them. `replayControl`
// relies on this order.
// Relies on forge's record shape (`transactions`, `receipts`, `chain`, `timestamp`). A JSON file without the
// first two is not a record and is dropped silently, as are the `dry-run` and `multi` directories met while searching a
// directory.

import { readFileSync, readdirSync, statSync, existsSync } from 'node:fs';
import { join, basename, dirname, resolve } from 'node:path';

import { COMMON, canonical, commonSig, fromAbiInput, lc, selectorOf } from './abi.mjs';

export const statusOf = (r) => (!r ? 'unknown' : Number(r.status) === 1 ? 'ok' : 'reverted');

export function readRecords(paths) {
  const files = [];
  for (const p of paths) walkRecords(p, files);
  return files.map(readRecord).filter(Boolean).sort((a, b) => a.ts - b.ts || a.file.localeCompare(b.file));
}

// Selectors any record names, plus a few common ones.
export function knownSignatures(records) {
  const knownSigs = new Map(COMMON.map((p) => [selectorOf(commonSig(p)), commonSig(p)]));
  for (const r of records) {
    for (const t of r.j.transactions) {
      const sig = t.function || (/^\w+\(.*\)$/.test(t.contractName || '') ? t.contractName : null);
      if (sig) knownSigs.set(selectorOf(sig.replace(/\s+/g, '')), sig);
    }
  }
  return knownSigs;
}

// One entry per chain and hash, with the last receipt seen. Mined transactions of a chain are ordered by block and
// index, not by the record file that holds them; unmined ones keep their place.
export function mergeTransactions(records) {
  const byHash = new Map();
  const txs = [];
  for (const r of records) {
    const receipts = new Map(r.j.receipts.map((x) => [lc(x.transactionHash), x]));
    r.j.transactions.forEach((t, idx) => {
      // The chain is part of the key: one signed transaction broadcast on two chains is two transactions.
      const key = t.hash
        ? `${r.chain}:${lc(t.hash)}`
        : `${r.chain}:${lc(t.transaction?.from)}:${t.transaction?.nonce}:${r.file}:${idx}`;
      let e = byHash.get(key);
      if (!e) {
        e = { key, rec: r, t, receipt: null, sig: r.sig };
        byHash.set(key, e);
        txs.push(e);
      }
      if (r.sig && !e.sig) e.sig = r.sig;
      const rc = t.hash && receipts.get(lc(t.hash));
      if (rc) e.receipt = rc;
    });
  }

  // A replaced transaction (same sender and nonce, never mined) gives way to the one that was.
  const nonceKey = (e) => `${e.rec.chain}:${lc(e.t.transaction?.from)}:${Number(e.t.transaction?.nonce)}`;
  const mined = new Set(txs.filter((e) => e.receipt).map(nonceKey));
  const kept = txs.filter((e) => e.receipt || !mined.has(nonceKey(e)));

  // Each chain's mined transactions are sorted into the positions they already hold, so nothing else moves.
  const pos = (e) => [Number(e.receipt.blockNumber), Number(e.receipt.transactionIndex) || 0];
  const minedAt = new Map();
  kept.forEach((e, k) => e.receipt && minedAt.set(e.rec.chain, [...(minedAt.get(e.rec.chain) || []), k]));
  for (const ks of minedAt.values()) {
    const sorted = ks.map((k) => kept[k]).sort((a, b) => pos(a)[0] - pos(b)[0] || pos(a)[1] - pos(b)[1]);
    ks.forEach((k, n) => (kept[k] = sorted[n]));
  }
  return kept;
}

// out/ is read on demand: a name's ABI once, every signature only when a selector is otherwise unknown.
export class Abis {
  constructor(out) {
    this.out = out && existsSync(out) ? out : null;
    this.cache = new Map();
    this.selectors = null;
  }

  contract(name) {
    if (!this.out || !name) return null;
    if (this.cache.has(name)) return this.cache.get(name);

    let abi = null;
    const direct = join(this.out, `${name}.sol`, `${name}.json`);
    const files = existsSync(direct)
      ? [direct]
      : readdirSync(this.out).map((d) => join(this.out, d, `${name}.json`)).filter(existsSync);
    for (const f of files) {
      try {
        abi = JSON.parse(readFileSync(f, 'utf8')).abi;
        if (abi) break;
      } catch {}
    }
    this.cache.set(name, abi);
    return abi;
  }

  constructorParams(name, n) {
    const c = (this.contract(name) || []).find((e) => e.type === 'constructor');
    return c && c.inputs.length === n ? c.inputs.map(fromAbiInput) : null;
  }

  functionParams(name, sig) {
    for (const e of this.contract(name) || []) {
      if (e.type !== 'function') continue;
      const ps = e.inputs.map(fromAbiInput);
      if (`${e.name}(${ps.map(canonical).join(',')})` === sig) return ps;
    }
    return null;
  }

  allSelectors() {
    if (this.selectors) return this.selectors;
    this.selectors = new Map();
    if (!this.out) return this.selectors;

    for (const d of readdirSync(this.out)) {
      let files;
      try { files = readdirSync(join(this.out, d)); } catch { continue; }
      for (const f of files) {
        if (!f.endsWith('.json')) continue;
        try {
          const ids = JSON.parse(readFileSync(join(this.out, d, f), 'utf8')).methodIdentifiers || {};
          for (const [sig, sel] of Object.entries(ids)) this.selectors.set('0x' + sel, sig);
        } catch {}
      }
    }
    return this.selectors;
  }
}

function walkRecords(p, out) {
  const st = statSync(p);
  if (st.isDirectory()) {
    for (const e of readdirSync(p).sort()) {
      if (e === 'dry-run' || e === 'multi') continue;
      walkRecords(join(p, e), out);
    }
  } else if (p.endsWith('.json')) out.push(p);
}

// `sig` is the script function a `<sig>-latest.json` names; a `run-<ts>.json` has none. A timestamp below 1e12 is taken
// as seconds.
function readRecord(file) {
  let j;
  try {
    j = JSON.parse(readFileSync(file, 'utf8'));
  } catch {
    return null;
  }
  if (!j || !Array.isArray(j.transactions) || !Array.isArray(j.receipts)) return null;

  const parts = resolve(file).split(/[\\/]/);
  const script = [...parts].reverse().find((s) => /\.sol$/.test(s)) ?? basename(dirname(dirname(file)));
  const fname = basename(file);
  const sig = /^run-\d+\.json$/.test(fname) ? null : fname.replace(/-latest\.json$/, '').replace(/\.json$/, '');
  let ts = Number(j.timestamp) || 0;
  if (ts && ts < 1e12) ts *= 1000;
  const chain = Number(j.chain) || Number(parts[parts.length - 2]) || 0;
  return { file, script, sig, ts, chain, j };
}

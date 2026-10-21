#!/usr/bin/env node
// Spike: a static HTML map of a Foundry deployment, from forge's broadcast records. See README.md.
import { readFileSync, readdirSync, statSync, existsSync } from 'node:fs';
import { join, basename, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const USAGE = `usage: node map.mjs [--project <dir>] [--sprue <project dir> <network>] [--title <text>] <broadcast dir or record files...> > map.html
  --project <dir>   read constructor and function parameter names from <dir>/out
  --sprue <dir> <network>
                    add role names, certificate-verified links and step ids from <dir>/deployments/<network>;
                    implies --project <dir>, and <dir>/broadcast when no records are named`;

// ---------- keccak256 (selectors only, so BigInt lanes are fast enough) ----------

const M64 = (1n << 64n) - 1n;
const RC = [
  0x1n, 0x8082n, 0x800000000000808an, 0x8000000080008000n, 0x808bn, 0x80000001n, 0x8000000080008081n,
  0x8000000000008009n, 0x8an, 0x88n, 0x80008009n, 0x8000000an, 0x8000808bn, 0x800000000000008bn,
  0x8000000000008089n, 0x8000000000008003n, 0x8000000000008002n, 0x8000000000000080n, 0x800an,
  0x800000008000000an, 0x8000000080008081n, 0x8000000000008080n, 0x80000001n, 0x8000000080008008n,
];
const ROT = [[0, 36, 3, 41, 18], [1, 44, 10, 45, 2], [62, 6, 43, 15, 61], [28, 55, 25, 21, 56], [27, 20, 39, 8, 14]];
const rotl = (x, n) => (n === 0 ? x : ((x << BigInt(n)) | (x >> BigInt(64 - n))) & M64);

function keccakF(s) {
  for (let r = 0; r < 24; r++) {
    const C = [0, 1, 2, 3, 4].map((x) => s[x] ^ s[x + 5] ^ s[x + 10] ^ s[x + 15] ^ s[x + 20]);
    for (let x = 0; x < 5; x++) {
      const D = C[(x + 4) % 5] ^ rotl(C[(x + 1) % 5], 1);
      for (let y = 0; y < 25; y += 5) s[y + x] ^= D;
    }
    const B = new Array(25);
    for (let x = 0; x < 5; x++) for (let y = 0; y < 5; y++) B[y + 5 * ((2 * x + 3 * y) % 5)] = rotl(s[x + 5 * y], ROT[x][y]);
    for (let x = 0; x < 5; x++)
      for (let y = 0; y < 5; y++) s[x + 5 * y] = B[x + 5 * y] ^ (~B[((x + 1) % 5) + 5 * y] & M64 & B[((x + 2) % 5) + 5 * y]);
    s[0] ^= RC[r];
  }
}

export function keccak256(bytes) {
  const rate = 136;
  const padded = new Uint8Array(Math.ceil((bytes.length + 1) / rate) * rate);
  padded.set(bytes);
  padded[bytes.length] ^= 0x01;
  padded[padded.length - 1] ^= 0x80;
  const s = new Array(25).fill(0n);
  for (let off = 0; off < padded.length; off += rate) {
    for (let i = 0; i < rate / 8; i++) {
      let lane = 0n;
      for (let b = 7; b >= 0; b--) lane = (lane << 8n) | BigInt(padded[off + i * 8 + b]);
      s[i] ^= lane;
    }
    keccakF(s);
  }
  let hex = '';
  for (let i = 0; i < 4; i++) for (let b = 0; b < 8; b++) hex += ((s[i] >> BigInt(8 * b)) & 0xffn).toString(16).padStart(2, '0');
  return hex;
}

const selectorOf = (sig) => '0x' + keccak256(new TextEncoder().encode(sig)).slice(0, 8);

// ---------- types and signatures ----------

// A type tree: {k:'base',t} | {k:'arr',of,len} | {k:'tuple',comps}; any node may carry `name`.
function splitTop(s, sep = ',') {
  const out = [];
  let depth = 0, cur = '';
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (c === '(' || c === '[') depth++;
    else if (c === ')' || c === ']') depth--;
    if (depth === 0 && s.startsWith(sep, i)) {
      out.push(cur);
      cur = '';
      i += sep.length - 1;
    } else cur += c;
  }
  if (cur.trim() !== '' || out.length) out.push(cur);
  return out;
}

// One parameter as written in a signature or a human-readable ABI: `(address a, bool b)[] feeds`, `uint256 x`.
function parseParam(text) {
  let s = text.trim();
  let t;
  if (s.startsWith('(') || s.startsWith('tuple(')) {
    if (s.startsWith('tuple')) s = s.slice(5);
    let depth = 0, end = -1;
    for (let i = 0; i < s.length; i++) {
      if (s[i] === '(') depth++;
      else if (s[i] === ')' && --depth === 0) { end = i; break; }
    }
    if (end < 0) throw new Error('unbalanced tuple: ' + text);
    t = { k: 'tuple', comps: parseParams(s.slice(1, end)) };
    s = s.slice(end + 1);
  } else {
    const m = /^([A-Za-z_][A-Za-z0-9_]*)/.exec(s);
    if (!m) throw new Error('bad type: ' + text);
    let base = m[1];
    if (base === 'uint') base = 'uint256';
    if (base === 'int') base = 'int256';
    t = { k: 'base', t: base };
    s = s.slice(m[1].length);
  }
  let m;
  while ((m = /^\[(\d*)\]/.exec(s))) {
    t = { k: 'arr', of: t, len: m[1] === '' ? null : Number(m[1]) };
    s = s.slice(m[0].length);
  }
  const words = s.trim().split(/\s+/).filter((w) => w && !['memory', 'calldata', 'storage', 'indexed', 'payable'].includes(w));
  if (words.length) t.name = words[words.length - 1];
  return t;
}

function parseParams(list) {
  return list.trim() === '' ? [] : splitTop(list).map(parseParam);
}

// `name(types)` or `function name(type a, ...) returns (...)` → {name, params}
export function parseSignature(sig) {
  const s = sig.trim().replace(/^function\s+/, '').replace(/^constructor\s*/, 'constructor');
  const open = s.indexOf('(');
  if (open < 0) return null;
  let depth = 0, close = -1;
  for (let i = open; i < s.length; i++) {
    if (s[i] === '(') depth++;
    else if (s[i] === ')' && --depth === 0) { close = i; break; }
  }
  if (close < 0) return null;
  try {
    return { name: s.slice(0, open).trim(), params: parseParams(s.slice(open + 1, close)) };
  } catch {
    return null;
  }
}

const canonical = (t) =>
  t.k === 'base' ? t.t : t.k === 'arr' ? `${canonical(t.of)}[${t.len ?? ''}]` : `(${t.comps.map(canonical).join(',')})`;

function fromAbiInput(inp) {
  let t;
  const m = /^tuple((?:\[\d*\])*)$/.exec(inp.type);
  if (m) {
    t = { k: 'tuple', comps: (inp.components || []).map(fromAbiInput) };
    for (const d of m[1].match(/\[\d*\]/g) || []) t = { k: 'arr', of: t, len: d === '[]' ? null : Number(d.slice(1, -1)) };
  } else t = parseParam(inp.type);
  if (inp.name) t.name = inp.name;
  return t;
}

// Copies names from `named` onto the same-shaped `typed`; a shape mismatch keeps `typed` as it is.
function withNames(typed, named) {
  if (!named || typed.length !== named.length) return typed;
  const one = (a, b) => {
    if (canonical(a) !== canonical(b)) return a;
    const c = { ...a, name: b.name ?? a.name };
    if (a.k === 'tuple') c.comps = a.comps.map((x, i) => one(x, b.comps[i]));
    if (a.k === 'arr') c.of = one(a.of, b.of);
    return c;
  };
  return typed.map((t, i) => one(t, named[i]));
}

// ---------- decoding ----------

const ADDR = /^0x[0-9a-fA-F]{40}$/;
const ADDR_IN = /(?<![0-9a-fA-Fx])0x[0-9a-fA-F]{40}(?![0-9a-fA-F])/g;

// forge's argument strings: arrays `[a, b]`, tuples `(a, b)`, strings unquoted. Throws on a shape mismatch.
function parseArgString(t, s) {
  s = String(s).trim();
  if (t.k === 'base') return { type: t, value: s };
  const [open, close] = t.k === 'tuple' ? ['(', ')'] : ['[', ']'];
  if (!s.startsWith(open) || !s.endsWith(close)) throw new Error('shape');
  const inner = s.slice(1, -1);
  const parts = inner.trim() === '' ? [] : splitTop(inner, ', ');
  const kids = t.k === 'tuple' ? t.comps : parts.map(() => t.of);
  if (kids.length !== parts.length || (t.k === 'arr' && t.len !== null && t.len !== parts.length)) throw new Error('shape');
  return { type: t, children: parts.map((p, i) => parseArgString(kids[i], p)) };
}

function word(hex, pos) {
  const w = hex.slice(pos * 2, pos * 2 + 64);
  if (w.length !== 64) throw new Error('short calldata');
  return w;
}
const isDyn = (t) =>
  t.k === 'base' ? t.t === 'bytes' || t.t === 'string' : t.k === 'arr' ? t.len === null || isDyn(t.of) : t.comps.some(isDyn);
const headSize = (t) => (isDyn(t) ? 32 : t.k === 'base' ? 32 : t.k === 'arr' ? t.len * headSize(t.of) : t.comps.reduce((a, c) => a + headSize(c), 0));

function decTuple(types, hex, start) {
  let p = start;
  return types.map((t) => {
    let v;
    if (isDyn(t)) {
      const off = Number(BigInt('0x' + word(hex, p)));
      if (off > hex.length) throw new Error('bad offset');
      v = decAt(t, hex, start + off);
      p += 32;
    } else {
      v = decAt(t, hex, p);
      p += headSize(t);
    }
    return v;
  });
}

function decAt(t, hex, pos) {
  if (t.k === 'tuple') return { type: t, children: decTuple(t.comps, hex, pos) };
  if (t.k === 'arr') {
    if (t.len !== null) return { type: t, children: decTuple(Array(t.len).fill(t.of), hex, pos) };
    const n = Number(BigInt('0x' + word(hex, pos)));
    if (n > 10000) throw new Error('bad length');
    return { type: t, children: decTuple(Array(n).fill(t.of), hex, pos + 32) };
  }
  const w = word(hex, pos), b = t.t;
  if (b === 'address') {
    if (!/^0{24}/.test(w)) throw new Error('dirty address');
    return { type: t, value: '0x' + w.slice(24) };
  }
  if (b === 'bool') return { type: t, value: String(BigInt('0x' + w) !== 0n) };
  if (/^uint/.test(b)) return { type: t, value: BigInt('0x' + w).toString() };
  if (/^int/.test(b)) {
    const bits = Number(b.slice(3) || 256);
    let v = BigInt('0x' + w) & ((1n << BigInt(bits)) - 1n);
    if (v >> BigInt(bits - 1)) v -= 1n << BigInt(bits);
    return { type: t, value: v.toString() };
  }
  if (/^bytes\d+$/.test(b)) return { type: t, value: '0x' + w.slice(0, Number(b.slice(5)) * 2) };
  if (b === 'bytes' || b === 'string') {
    const n = Number(BigInt('0x' + w));
    const data = hex.slice((pos + 32) * 2, (pos + 32 + n) * 2);
    if (data.length !== n * 2) throw new Error('short bytes');
    return { type: t, value: b === 'bytes' ? '0x' + data : Buffer.from(data, 'hex').toString('utf8') };
  }
  throw new Error('unknown type ' + b);
}

// Leaves as {path, name, type, value}; `path` is the parameter name (or arg<i>) with indices.
function leaves(trees) {
  const out = [];
  const walk = (n, path, name) => {
    if (n.children) n.children.forEach((c, i) => walk(c, n.type.k === 'arr' ? `${path}[${i}]` : `${path}.${c.type.name ?? i}`, c.type.name ?? name));
    else out.push({ path, name, type: n.type.k === 'base' ? n.type.t : '?', value: n.value });
  };
  trees.forEach((n, i) => walk(n, n.type.name ?? `arg${i}`, n.type.name ?? null));
  return out;
}

function show(tree) {
  if (tree.children) {
    const inner = tree.children.map(show).join(', ');
    return tree.type.k === 'tuple' ? `(${inner})` : `[${inner}]`;
  }
  return String(tree.value);
}

// ---------- reading records ----------

function walkRecords(p, out) {
  const st = statSync(p);
  if (st.isDirectory()) {
    for (const e of readdirSync(p).sort()) {
      if (e === 'dry-run' || e === 'multi') continue;
      walkRecords(join(p, e), out);
    }
  } else if (p.endsWith('.json')) out.push(p);
}

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

const lc = (a) => (a ? String(a).toLowerCase() : a);
const statusOf = (r) => (!r ? 'unknown' : Number(r.status) === 1 ? 'ok' : 'reverted');

// ---------- ABIs from out/ ----------

class Abis {
  constructor(dir) {
    this.out = dir && existsSync(join(dir, 'out')) ? join(dir, 'out') : null;
    this.cache = new Map();
    this.selectors = null;
  }
  contract(name) {
    if (!this.out || !name) return null;
    if (this.cache.has(name)) return this.cache.get(name);
    let abi = null;
    const direct = join(this.out, `${name}.sol`, `${name}.json`);
    const files = existsSync(direct) ? [direct] : readdirSync(this.out).map((d) => join(this.out, d, `${name}.json`)).filter(existsSync);
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
  // Every function signature under out/, read only when a selector is otherwise unknown.
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

const COMMON = [
  'transferOwnership(address newOwner)', '_transferOwnership(address newOwner)', 'acceptOwnership()', 'renounceOwnership()',
  'grantRole(bytes32 role, address account)', 'revokeRole(bytes32 role, address account)', 'renounceRole(bytes32 role, address account)',
  'setOwner(address owner)', 'setAdmin(address admin)', 'changeAdmin(address newAdmin)', 'upgradeTo(address newImplementation)',
  'upgradeToAndCall(address newImplementation, bytes data)', 'initialize()', 'approve(address spender, uint256 amount)',
  'transfer(address to, uint256 amount)', 'transferFrom(address from, address to, uint256 amount)', 'mint(address to, uint256 amount)',
].map(parseSignature);
const commonSig = (p) => `${p.name}(${p.params.map(canonical).join(',')})`;

// ---------- control rules ----------

// First match wins. `authority` rules mark a contract as controlled by the address; `setter` rules only flag the edge.
const RULES = [
  { id: 'fn:ownership', cls: 'authority', fn: /^_?(transferOwnership|setOwner|changeOwner|setPendingOwner|setAdmin|changeAdmin|transferAdmin)$/i },
  { id: 'fn:role', cls: 'authority', fn: /^_?(grantRoles?|revokeRoles?|setRole)/i },
  { id: 'param:owner', cls: 'authority', param: /owner/i },
  { id: 'param:admin', cls: 'authority', param: /admin/i },
  { id: 'param:role', cls: 'authority', param: /role/i },
  { id: 'param:minter', cls: 'authority', param: /minter/i },
  { id: 'param:governor', cls: 'authority', param: /govern|guardian|pauser|authority/i },
  { id: 'param:treasury', cls: 'control', param: /treasury/i },
  { id: 'fn:set*/bind*', cls: 'setter', fn: /^_?(set|bind)([A-Z_]|$)/ },
];

function matchRule(fnName, leaf) {
  for (const r of RULES) {
    if (r.fn && fnName && r.fn.test(fnName)) return r;
    if (r.param && ((leaf.name && r.param.test(leaf.name)) || (leaf.path && r.param.test(leaf.path.split(/[.[]/)[0])))) return r;
  }
  return null;
}

// ---------- the model ----------

export function build({ paths, project, sprue }) {
  const files = [];
  for (const p of paths) walkRecords(p, files);
  const records = files.map(readRecord).filter(Boolean).sort((a, b) => a.ts - b.ts || a.file.localeCompare(b.file));
  const abis = new Abis(project);
  const warnings = [];

  // Selectors any record names, plus a few common ones.
  const knownSigs = new Map(COMMON.map((p) => [selectorOf(commonSig(p)), commonSig(p)]));
  for (const r of records)
    for (const t of r.j.transactions) {
      const sig = t.function || (/^\w+\(.*\)$/.test(t.contractName || '') ? t.contractName : null);
      if (sig) knownSigs.set(selectorOf(sig.replace(/\s+/g, '')), sig);
    }

  // Merge: one entry per hash, at its first position, with the last receipt seen.
  const byHash = new Map();
  const txs = [];
  for (const r of records) {
    const receipts = new Map(r.j.receipts.map((x) => [lc(x.transactionHash), x]));
    r.j.transactions.forEach((t, idx) => {
      const key = t.hash ? lc(t.hash) : `${r.chain}:${lc(t.transaction?.from)}:${t.transaction?.nonce}:${r.file}:${idx}`;
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
  const mined = new Set(txs.filter((e) => e.receipt).map((e) => `${e.rec.chain}:${lc(e.t.transaction?.from)}:${Number(e.t.transaction?.nonce)}`));
  const kept = txs.filter((e) => e.receipt || !mined.has(`${e.rec.chain}:${lc(e.t.transaction?.from)}:${Number(e.t.transaction?.nonce)}`));

  const nodes = new Map();
  const nodeOf = (chain, addr) => nodes.get(`${chain}:${lc(addr)}`);
  const ensure = (chain, addr, init) => {
    const id = `${chain}:${lc(addr)}`;
    let n = nodes.get(id);
    if (!n) {
      n = { id, chain, addr: lc(addr), kind: 'outside', name: null, created: null, lane: null, refs: 0, firstRef: Infinity };
      nodes.set(id, n);
    }
    Object.assign(n, init || {});
    return n;
  };

  const out = [];
  // Pass 1: transactions and the contracts they create.
  kept.forEach((e, i) => {
    const { t, rec, receipt } = e;
    const tx = t.transaction || {};
    const status = statusOf(receipt);
    const chain = rec.chain;
    const type = t.transactionType;
    const input = tx.input ?? tx.data ?? null;
    const x = {
      i, chain, script: rec.script, sig: e.sig, type, hash: t.hash || null, from: lc(tx.from), to: lc(type === 'CALL' ? tx.to : t.contractAddress),
      contractName: /\(/.test(t.contractName || '') ? null : t.contractName || null,
      fn: t.function || (/^\w+\(.*\)$/.test(t.contractName || '') ? t.contractName : null),
      functionAbi: t.functionAbi || null, arguments: t.arguments ?? null, input, value: tx.value && BigInt(tx.value) !== 0n ? BigInt(tx.value).toString() : null,
      status, block: receipt ? Number(receipt.blockNumber) : null, created: [], step: null,
    };
    out.push(x);
    ensure(chain, x.from).sender = true;
    if (status === 'reverted') return;
    const lane = `${chain}|${rec.script}`;
    if (type === 'CREATE' || type === 'CREATE2') {
      const n = ensure(chain, t.contractAddress, { kind: 'contract', lane, created: i });
      n.name = n.name || x.contractName;
      x.created.push(n.id);
    }
    // A factory's children; an unnamed CREATE2 followed by a CREATE is a CREATE3 intermediate, folded into the edge.
    const kids = t.additionalContracts || [];
    const factory = type === 'CALL' ? x.to : lc(t.contractAddress);
    kids.forEach((c, k) => {
      const next = kids[k + 1];
      if (c.transactionType === 'CREATE2' && !c.contractName && next && next.transactionType === 'CREATE') return;
      const prev = kids[k - 1];
      const via = prev && prev.transactionType === 'CREATE2' && !prev.contractName && c.transactionType === 'CREATE' ? lc(prev.address) : null;
      const n = ensure(chain, c.address, { kind: 'contract', lane, created: i });
      n.name = n.name || c.contractName || null;
      n.createdBy = { factory, via };
      x.created.push(n.id);
    });
  });

  // Names forge knew from later calls (a factory's unnamed child).
  for (const x of out) if (x.type === 'CALL' && x.contractName) {
    const n = nodeOf(x.chain, x.to);
    if (n && !n.name) n.name = x.contractName;
  }

  // Pass 2: decode arguments and match addresses to nodes by value.
  const edges = new Map();
  const addEdge = (from, to, kind, label, rule, x, decoded, detail) => {
    if (!from || !to || from === to) return;
    const id = `${kind}|${from}|${to}|${label}`;
    let ed = edges.get(id);
    if (!ed) {
      ed = { id, from, to, kind, label, rule: rule ? rule.id : null, cls: rule ? rule.cls : null, decoded, txs: [], verified: false };
      edges.set(id, ed);
    }
    ed.decoded = ed.decoded && decoded;
    if (!ed.txs.some((d) => d.i === x.i)) ed.txs.push({ i: x.i, detail });
  };
  const stats = { txs: out.length, decode: { record: 0, abi: 0, positional: 0, raw: 0, none: 0, failed: 0 } };

  for (const x of out) {
    const chain = x.chain;
    const isCreate = x.type === 'CREATE' || x.type === 'CREATE2';
    let fnName = null, params = null, trees = null, mode = 'none';
    if (isCreate) {
      const args = x.arguments || [];
      if (args.length) {
        const named = abis.constructorParams(x.contractName, args.length);
        if (named) {
          try {
            trees = named.map((t, k) => parseArgString(t, args[k]));
            mode = 'record';
          } catch { trees = null; }
        }
        if (!trees) {
          trees = args.map((a, k) => ({ type: { k: 'base', t: ADDR.test(String(a).trim()) ? 'address' : '?', name: `arg${k}` }, value: String(a) }));
          mode = 'positional';
        }
      }
    } else {
      const sel = x.input && x.input.length >= 10 ? x.input.slice(0, 10).toLowerCase() : null;
      let sig = x.fn;
      if (!sig && sel) sig = knownSigs.get(sel) || abis.allSelectors().get(sel) || null;
      const parsed = sig && parseSignature(sig);
      if (parsed) {
        fnName = parsed.name;
        x.fn = `${parsed.name}(${parsed.params.map(canonical).join(',')})`;
        const fromAbi = x.functionAbi && parseSignature(x.functionAbi);
        params = withNames(parsed.params, fromAbi?.params || abis.functionParams(nodeOf(chain, x.to)?.name || x.contractName, x.fn)
          || COMMON.find((p) => commonSig(p) === x.fn)?.params);
        if (x.arguments && x.arguments.length === params.length) {
          try {
            trees = params.map((t, k) => parseArgString(t, x.arguments[k]));
            mode = 'record';
          } catch { trees = null; }
        }
        if (!trees && x.input) {
          try {
            trees = decTuple(params, x.input.slice(10), 0);
            mode = 'abi';
          } catch { trees = null; }
        }
        if (!trees && x.arguments && x.arguments.length === params.length) {
          trees = params.map((t, k) => ({ type: { k: 'base', t: t.k === 'base' ? t.t : '?', name: t.name ?? `arg${k}` }, value: String(x.arguments[k]) }));
          mode = 'positional';
        }
        if (!trees && params.length === 0) mode = 'abi';
        if (!trees && params.length) mode = 'failed';
      } else if (sel) {
        x.fn = sel;
        mode = 'raw';
      }
    }
    x.decode = mode;
    stats.decode[mode]++;
    const ls = trees ? leaves(trees) : [];
    x.args = trees ? trees.map((t, k) => ({ name: t.type.name ?? `arg${k}`, type: t.type.k === 'base' ? t.type.t : canonical(t.type), value: show(t) })) : [];
    if (x.status === 'reverted') continue;

    const source = `${chain}:${x.to}`;
    const touch = (addr) => {
      const n = ensure(chain, addr);
      n.refs++;
      n.firstRef = Math.min(n.firstRef, x.i);
      return n.id;
    };
    if (!isCreate && x.to) touch(x.to);
    const label = (leaf) => (isCreate ? leaf.path : `${fnName}(${leaf.path})`);
    if (mode === 'raw' || mode === 'failed') {
      // No signature: a 32-byte word that holds a known address is a link, labelled by selector and word.
      const body = (x.input || '').slice(10);
      for (let w = 0; w * 64 + 64 <= body.length; w++) {
        const m = /^0{24}([0-9a-f]{40})$/.exec(body.slice(w * 64, w * 64 + 64).toLowerCase());
        if (m && /[1-9a-f]/.test(m[1]) && nodeOf(chain, '0x' + m[1])) {
          addEdge(source, touch('0x' + m[1]), 'call', `${x.fn} word ${w}`, null, x, false, `word ${w}`);
        }
      }
      continue;
    }
    // Initcode that the records do not split: constructor arguments sit at its end, so 32-byte words counted
    // from the end that hold a known address are links of the created contract, flagged as not decoded.
    const initcodes = isCreate ? (x.arguments ? [] : [x.input]) : x.created.length ? ls.filter((l) => l.type === 'bytes').map((l) => l.value) : [];
    for (const code of initcodes) {
      const hex = String(code || '').replace(/^0x/, '').toLowerCase();
      if (hex.length < 128) continue;
      const child = isCreate ? source : x.created[0];
      for (let w = 1; w <= Math.min(64, Math.floor(hex.length / 64)); w++) {
        const m = /^0{24}([0-9a-f]{40})$/.exec(hex.slice(hex.length - 64 * w, hex.length - 64 * (w - 1)));
        if (m && /[1-9a-f]/.test(m[1]) && nodeOf(chain, '0x' + m[1]))
          addEdge(child, touch('0x' + m[1]), 'deploy', `initcode word -${w}`, null, x, false, `initcode word -${w} from the end`);
      }
    }
    for (const leaf of ls) {
      const vals = leaf.type === 'address' && ADDR.test(String(leaf.value).trim()) ? [String(leaf.value).trim()]
        : leaf.type === '?' ? String(leaf.value).match(ADDR_IN) || [] : [];
      for (const v of vals) {
        if (/^0x0{40}$/.test(v)) continue;
        const rule = matchRule(isCreate ? null : fnName, leaf);
        addEdge(source, touch(v), isCreate ? 'deploy' : 'call', label(leaf), rule, x, true, `${leaf.path} = ${lc(v)}`);
      }
    }
  }
  // Factories' children.
  for (const n of nodes.values()) if (n.createdBy) {
    const x = out[n.created];
    addEdge(`${n.chain}:${n.createdBy.factory}`, n.id, 'created', n.createdBy.via ? 'created (CREATE3)' : 'created', null, x, true,
      n.createdBy.via ? `via ${n.createdBy.via}` : '');
    ensure(n.chain, n.createdBy.factory);
  }

  // Node kinds for what the deployment did not create.
  for (const n of nodes.values()) {
    if (n.kind === 'contract') continue;
    if (n.sender) n.kind = 'sender';
    else if (out.some((x) => x.type === 'CALL' && x.chain === n.chain && x.to === n.addr && x.status !== 'reverted')) {
      n.kind = 'outside-contract';
      n.name = n.name || (out.find((x) => x.type === 'CALL' && x.chain === n.chain && x.to === n.addr && x.contractName) || {}).contractName || null;
    }
  }

  // Steps: one per transaction, or per sprue plan step.
  let stepIds = null;
  if (sprue) stepIds = sprueLayer(sprue, out, nodes, edges, warnings);
  const steps = [];
  for (const x of out) {
    const sid = stepIds && stepIds.get(x.i);
    const last = steps[steps.length - 1];
    if (sid && last && last.id === sid) last.txs.push(x.i);
    else steps.push({ id: sid || null, txs: [x.i] });
  }
  steps.forEach((s, k) => s.txs.forEach((i) => (out[i].step = k)));
  for (const n of nodes.values()) {
    n.createdStep = n.created === null ? null : out[n.created].step;
    n.firstStep = n.created !== null ? n.createdStep : n.firstRef === Infinity ? 0 : out[n.firstRef].step;
  }
  const edgeList = [...edges.values()].map((e) => ({ ...e, firstStep: Math.min(...e.txs.map((d) => out[d.i].step)) }));

  // An outside address is named by how the records use it: the deployer, the parameter it was passed as, the
  // factory of a child, or the call it received.
  const nameOf = (n) => n.role || n.name || n.label || n.addr.slice(0, 6) + '…' + n.addr.slice(-4);
  const steps1 = (e) => e.firstStep;
  for (const n of nodes.values()) {
    if (n.kind === 'contract' || n.name) continue;
    if (n.kind === 'sender') { n.label = 'deployer'; continue; }
    const into = edgeList.filter((e) => e.to === n.id && e.kind !== 'created').sort((a, b) => !!b.rule - !!a.rule || steps1(a) - steps1(b));
    const made = edgeList.find((e) => e.from === n.id && e.kind === 'created');
    const called = out.find((x) => x.type === 'CALL' && x.chain === n.chain && x.to === n.addr && x.fn);
    if (into.length) {
      const e = into[0], src = nameOf(nodes.get(e.from));
      const m = /^(\w+)\((.*)\)$/.exec(e.label);
      n.label = e.kind === 'deploy' ? (/^initcode/.test(e.label) ? `in ${src} initcode` : `${e.label} of ${src}`)
        : m ? `${m[2]} via ${m[1]}` : `in ${e.label.split(' ')[0]} calldata`;
    } else if (made) n.label = `factory of ${nameOf(nodes.get(made.to))}`;
    else if (called) n.label = `target of ${called.fn.split('(')[0]}`;
  }

  // Contracts that an outside address controls.
  for (const e of edgeList) {
    const to = nodes.get(e.to), from = nodes.get(e.from);
    if (e.cls === 'authority' && to && from && to.kind !== 'contract') (from.controlledBy ||= []).push({ by: to.id, rule: e.rule });
  }

  const { list: nodeList, lanes } = layout([...nodes.values()], out);
  stats.nodes = nodeList.length;
  stats.contracts = nodeList.filter((n) => n.kind === 'contract').length;
  stats.edges = edgeList.length;
  stats.edgesDecoded = edgeList.filter((e) => e.decoded).length;
  stats.control = edgeList.filter((e) => e.rule).length;
  stats.rules = edgeList.reduce((a, e) => (e.rule ? ((a[e.rule] = (a[e.rule] || 0) + 1), a) : a), {});
  stats.steps = steps.length;
  stats.reverted = out.filter((x) => x.status === 'reverted').length;
  stats.verified = edgeList.filter((e) => e.verified).length;
  stats.records = records.length;
  return {
    nodes: nodeList.map(({ refs, firstRef, created, createdBy, sender, lane, ...n }) => ({ ...n, sender: !!sender, createdBy: createdBy ? createdBy.factory : null, via: createdBy?.via ?? null })),
    edges: edgeList,
    txs: out.map(({ arguments: _a, input, functionAbi, ...x }) => ({ ...x, selector: input && input.length >= 10 ? input.slice(0, 10) : null, bytes: input ? (input.length - 2) / 2 : 0 })),
    steps,
    lanes,
    stats,
    warnings,
    sprue: !!sprue,
  };
}

// ---------- sprue layer ----------

function sprueLayer({ dir, network }, out, nodes, edges, warnings) {
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
          if (e.from === n.id && e.kind === 'deploy' && vouched.has(e.to.split(':')[1])) e.verified = true;
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

// ---------- layout ----------

// Lane and rank only; the page places them for its width.
export const GEOM = { w: 190, h: 46, gx: 44, gy: 34, laneGap: 52, cols: 8, pad: 24, title: 26 };

function layout(list, out) {
  const lanes = [];
  const seen = new Set();
  const push = (k) => { if (!seen.has(k)) { seen.add(k); lanes.push(k); } };
  for (const x of out) {
    push(`${x.chain}|outside`);
    push(`${x.chain}|${x.script}`);
  }
  for (const n of list) {
    n.laneKey = n.kind === 'contract' ? n.lane : `${n.chain}|outside`;
    push(n.laneKey);
  }
  const rank = (n) => (n.kind === 'contract' ? n.created : n.sender ? -1 : n.firstRef);
  [...list].sort((a, b) => rank(a) - rank(b) || a.addr.localeCompare(b.addr)).forEach((n, k) => (n.ord = k));
  return { list, lanes };
}

// Places nodes and routes links for a page width. Runs in the page (serialised), so it must not use anything
// outside its own body. Positions depend on the deployment and the width only, never on the step.
// Links run only in the gaps between rows, lanes and columns, so no link crosses a box. Links into one node
// share its entry point and their channel tracks, so they merge into one trunk. Each trunk or bus owns a track
// of every channel it uses, and channels widen until their tracks fit, so parallel links never draw over each other.
export function place(D, G, avail) {
  const g = avail < 560 ? { ...G, w: 148, gx: 24, pad: 8 } : { ...G };
  const SP = g.w < G.w ? 6 : 8;
  const byId = new Map(D.nodes.map((n) => [n.id, n]));
  const bundles = new Map();
  for (const e of D.edges) {
    if (!byId.has(e.from) || !byId.has(e.to)) continue;
    const k = e.from + '>' + e.to;
    if (!bundles.has(k)) bundles.set(k, { key: k, from: e.from, to: e.to, edges: [] });
    bundles.get(k).edges.push(e);
  }
  const nbrs = new Map(D.nodes.map((n) => [n.id, new Set()]));
  for (const b of bundles.values()) {
    nbrs.get(b.from).add(b.to);
    nbrs.get(b.to).add(b.from);
  }

  // Contracts sit in their script's lane; an outside address that links into one lane only joins it, one
  // linked to no contract joins its chain's first lane; the others (the deployer, shared owners) go to their
  // chain's side column.
  const lanes = new Map();
  for (const k of D.lanes) if (!k.endsWith('|outside')) lanes.set(k, { key: k, chain: k.split('|')[0], nodes: [] });
  const side = new Map();
  for (const n of [...D.nodes].sort((a, b) => (a.kind !== 'contract') - (b.kind !== 'contract') || a.ord - b.ord)) {
    if (n.kind === 'contract') {
      lanes.get(n.laneKey).nodes.push(n);
      continue;
    }
    const into = new Set([...nbrs.get(n.id)].map((id) => byId.get(id)).filter((m) => m.kind === 'contract').map((m) => m.laneKey));
    const first = [...lanes.values()].find((l) => l.chain === String(n.chain) && l.nodes.length);
    if (into.size === 1) lanes.get([...into][0]).nodes.push(n);
    else if (!into.size && first) first.nodes.push(n);
    else {
      const c = String(n.chain);
      if (!side.has(c)) side.set(c, []);
      side.get(c).push(n);
    }
  }
  const gutter = g.gx + 16;
  // Too narrow for a side column beside two grid columns: the shared addresses become their chain's first lane.
  if (side.size && avail - 2 * g.pad - g.w - gutter < 2 * g.w + g.gx) {
    const all = [...lanes.values()];
    lanes.clear();
    for (const [c, ns] of side) lanes.set(c + '|shared outside', { key: c + '|shared outside', chain: c, nodes: ns });
    for (const l of all) lanes.set(l.key, l);
    side.clear();
  }
  const laneList = [...lanes.values()].filter((l) => l.nodes.length);
  const hasSide = side.size > 0;
  const x0 = hasSide ? g.pad + g.w : 0, gap0 = hasSide ? gutter : 2 * g.pad + 8;
  const fit = Math.max(1, Math.min(G.cols, Math.floor((avail - x0 - gap0 - g.pad) / (g.w + g.gx))));
  // Widened gaps can overflow the width: then one column fewer, down to two.
  for (let cols = fit; ; cols--) {
    const L = attempt(cols);
    if (L.W <= avail || cols <= Math.min(2, fit)) return L;
  }

  function attempt(cols) {
    // Shelves: consecutive lanes of one chain that fit side by side in one row share it, in deploy order, so a
    // short lane leaves no empty row behind it. A lane alone on its shelf may use any column.
    const shelves = [];
    for (const l of laneList) {
      const need = Math.min(l.nodes.length, cols), s = shelves[shelves.length - 1];
      if (s && s.chain === l.chain && s.used + need <= cols) {
        l.c0 = s.used;
        s.used += need;
        s.lanes.push(l);
      } else {
        l.c0 = 0;
        shelves.push({ chain: l.chain, lanes: [l], used: need });
      }
      l.shelf = shelves[shelves.length - 1];
    }
    for (const l of laneList) l.span = l.shelf.lanes.length > 1 ? l.nodes.length : cols;
    // Columns: barycenter sweeps over the lanes. A lane that fits in one row puts each node at the free column
    // nearest its barycenter, so linked nodes line up; a longer lane spreads over every column, filling column
    // by column, so a node's x still follows its barycenter.
    const cell = new Map();
    const assign = (l, bary) => {
      const n = l.nodes.length;
      if (n <= l.span) {
        l.rows = 1;
        let prev = l.c0 - 1;
        l.nodes.forEach((m, k) => {
          const want = bary ? Math.round(bary.get(m.id)) : l.c0 + k;
          prev = Math.min(Math.max(prev + 1, want), l.c0 + l.span - (n - k));
          cell.set(m.id, { c: prev, r: 0 });
        });
        return;
      }
      const at = new Map();
      l.nodes.forEach((m, k) => {
        const c = Math.floor((k * cols) / n);
        at.set(c, (at.get(c) || 0) + 1);
        cell.set(m.id, { c, r: at.get(c) - 1 });
      });
      l.rows = Math.max(...at.values());
    };
    laneList.forEach((l) => assign(l));
    const colOf = (id) => (cell.has(id) ? cell.get(id).c : -1);
    for (let it = 0; it < 6; it++) {
      for (const l of it % 2 ? [...laneList].reverse() : laneList) {
        const own = new Set(l.nodes.map((n) => n.id));
        const idx = new Map(l.nodes.map((n, k) => [n.id, k]));
        const bary = new Map(l.nodes.map((n) => {
          const xs = [...nbrs.get(n.id)].filter((id) => !own.has(id)).map(colOf);
          return [n.id, xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : colOf(n.id)];
        }));
        l.nodes.sort((a, b) => bary.get(a.id) - bary.get(b.id) || idx.get(a.id) - idx.get(b.id));
        assign(l, bary);
      }
    }
    // Each channel needs a track per trunk or bus it carries; route, widen what overflowed, route again.
    const vw = Array(cols + 1).fill(g.gx);
    vw[0] = gap0;
    const widths = new Map();
    for (let it = 0; ; it++) {
      const L = route(cols, shelves, cell, vw, widths);
      let grew = false;
      for (const [key, n] of L.counts) {
        const need = 2 * (SP * Math.ceil((n - 1) / 2) + 6);
        if (key[0] === 'v') {
          if (need > vw[+key.slice(1)]) { vw[+key.slice(1)] = need; grew = true; }
        } else if (need > L.width.get(key)) { widths.set(key, need); grew = true; }
      }
      if (!grew || it > 20) return L;
    }
  }

  function route(cols, shelves, cell, vw, widths) {
    const colX = [], gapC = [];
    let x = x0;
    for (let i = 0; i <= cols; i++) {
      gapC.push(x + vw[i] / 2);
      x += vw[i];
      if (i < cols) { colX.push(x); x += g.w; }
    }
    const width = new Map();
    const chan = (id, top, base) => {
      const w = Math.max(base, widths.get(id) || 0);
      width.set(id, w);
      return { id, y: top + w / 2, w };
    };
    const box = new Map();
    const sides = [];
    let y = g.pad - g.laneGap / 2, k = 0, prev = null;
    for (const chain of [...new Set(D.lanes.map((key) => key.split('|')[0]))]) {
      let top = null;
      for (const l of shelves.filter((s) => s.chain === chain)) {
        l.rows = Math.max(...l.lanes.map((m) => m.rows));
        const above = prev || chan('b' + k++, y, g.laneGap);
        const y0 = above.y + above.w / 2;
        if (top === null) top = y0;
        const rowTop = [], inner = [];
        let ry = y0 + g.title;
        for (let r = 0; r < l.rows; r++) {
          rowTop.push(ry);
          ry += g.h;
          if (r < l.rows - 1) {
            inner.push(chan(`r${k}.${r}`, ry, g.gy));
            ry += inner[r].w;
          }
        }
        const y1 = ry + 10;
        const below = chan('b' + k++, y1, g.laneGap);
        Object.assign(l, { y0, y1 });
        l.above = (r) => (r === 0 ? above : inner[r - 1]);
        l.below = (r) => (r === l.rows - 1 ? below : inner[r]);
        for (const n of l.lanes.flatMap((m) => m.nodes)) {
          const { c, r } = cell.get(n.id);
          box.set(n.id, { x: colX[c], y: rowTop[r], shelf: l, row: r, col: c });
        }
        prev = below;
        y = y1;
      }
      const ns = side.get(chain) || [];
      if (ns.length) {
        if (top === null) top = y + g.laneGap / 2;
        const want = ns.map((n) => {
          const ys = [...nbrs.get(n.id)].map((id) => box.get(id)).filter(Boolean).map((b) => b.y);
          return { n, y: ys.length ? ys.reduce((a, b) => a + b, 0) / ys.length : top };
        }).sort((a, b) => a.y - b.y);
        let next = top + g.title;
        for (const w of want) {
          const at = Math.max(w.y, next);
          box.set(w.n.id, { x: g.pad, y: at, side: true });
          next = at + g.h + 14;
        }
        sides.push({ chain, y0: box.get(want[0].n.id).y - g.title, y1: next - 4 });
        if (next > y) {
          y = next;
          prev = null;
        }
      }
    }

    const tracks = new Map();
    const track = (key, by) => {
      if (!tracks.has(key)) tracks.set(key, []);
      const l = tracks.get(key);
      let i = l.indexOf(by);
      if (i < 0) i = l.push(by) - 1;
      return i === 0 ? 0 : (i % 2 ? 1 : -1) * Math.ceil(i / 2) * SP;
    };
    const cy = (b) => b.y + g.h / 2;
    // Top and bottom edges put their ports at different x, so stubs that meet in one channel from the rows
    // above and below never run along each other.
    const port = (b, top, out) => b.x + g.w / 2 + (out ? -1 : 1) * (top ? 12 : 24);
    const outDeg = new Map(), inDeg = new Map();
    for (const b of bundles.values()) {
      outDeg.set(b.from, (outDeg.get(b.from) || 0) + 1);
      inDeg.set(b.to, (inDeg.get(b.to) || 0) + 1);
    }
    const routes = [];
    for (const bd of bundles.values()) {
      const A = box.get(bd.from), B = box.get(bd.to), T = bd.to;
      // Near the source a channel track is shared by the source's links (a fan-out), near the target by the
      // target's (a trunk).
      const S = 's' + bd.from;
      // The middle of a route follows the busier end: a fan-out shares one bus, links into one node one trunk.
      const mid = outDeg.get(bd.from) > inDeg.get(bd.to) ? S : T;
      const h = (ch, by = T) => ch.y + track(ch.id, by);
      const v = (i, by = T) => gapC[i] + track('v' + i, by);
      let pts;
      if (A.side && B.side) {
        const xg = v(0);
        pts = [[A.x + g.w, cy(A) - 6], [xg, cy(A) - 6], [xg, cy(B) + 6], [B.x + g.w, cy(B) + 6]];
      } else if (B.side) {
        const up = cy(B) < cy(A), yc = h(up ? A.shelf.above(A.row) : A.shelf.below(A.row), S), xg = v(0), sx = port(A, up, true);
        pts = [[sx, up ? A.y : A.y + g.h], [sx, yc], [xg, yc], [xg, cy(B) + 6], [B.x + g.w, cy(B) + 6]];
      } else if (A.side) {
        const down = cy(B) > cy(A), yc = h(down ? B.shelf.above(B.row) : B.shelf.below(B.row)), xg = v(0, S), ex = port(B, down, false);
        pts = [[A.x + g.w, cy(A) - 6], [xg, cy(A) - 6], [xg, yc], [ex, yc], [ex, down ? B.y : B.y + g.h]];
      } else if (A.shelf === B.shelf && A.row === B.row) {
        if (Math.abs(A.col - B.col) === 1) {
          const right = A.col < B.col, yy = cy(A) + (bd.from < bd.to ? -6 : 6);
          pts = [[right ? A.x + g.w : A.x, yy], [right ? B.x : B.x + g.w, yy]];
        } else {
          const yc = h(A.shelf.below(A.row)), sx = port(A, false, true), ex = port(B, false, false);
          pts = [[sx, A.y + g.h], [sx, yc], [ex, yc], [ex, B.y + g.h]];
        }
      } else {
        const down = B.y > A.y;
        const c1 = down ? A.shelf.below(A.row) : A.shelf.above(A.row), c2 = down ? B.shelf.above(B.row) : B.shelf.below(B.row);
        const aEdge = down ? A.y + g.h : A.y, bEdge = down ? B.y : B.y + g.h, sx = port(A, !down, true), ex = port(B, down, false);
        if (c1.id === c2.id) {
          const yc = h(c1);
          pts = [[sx, aEdge], [sx, yc], [ex, yc], [ex, bEdge]];
        } else {
          const cost = (i) => Math.abs(gapC[i] - sx) + Math.abs(gapC[i] - ex);
          const gi = [B.col, B.col + 1, A.col, A.col + 1].reduce((a, b) => (cost(b) < cost(a) ? b : a));
          const xg = v(gi, mid), ya = h(c1, S), yb = h(c2);
          pts = [[sx, aEdge], [sx, ya], [xg, ya], [xg, yb], [ex, yb], [ex, bEdge]];
        }
      }
      let best = 0, at = [pts[0][0], pts[0][1]];
      for (let i = 1; i < pts.length; i++) {
        const len = Math.abs(pts[i][0] - pts[i - 1][0]) + Math.abs(pts[i][1] - pts[i - 1][1]);
        if (len > best) { best = len; at = [(pts[i][0] + pts[i - 1][0]) / 2, (pts[i][1] + pts[i - 1][1]) / 2]; }
      }
      routes.push({ ...bd, pts, labelAt: at });
    }
    // A trunk's count sits at its shared entry point.
    const entries = new Map();
    for (const r of routes) {
      const k = r.to + '@' + r.pts[r.pts.length - 1].join(',');
      if (!entries.has(k)) entries.set(k, { to: r.to, n: 0, a: r.pts[r.pts.length - 1], b: r.pts[r.pts.length - 2] });
      entries.get(k).n++;
    }
    const badges = [...entries.values()].filter((e) => e.n >= 3).map((e) => ({ to: e.to, n: e.n, x: (e.a[0] + e.b[0]) / 2, y: (e.a[1] + e.b[1]) / 2 }));
    const exits = new Map();
    for (const r of routes) {
      const k = r.from + '@' + r.pts[0].join(',');
      if (!exits.has(k)) exits.set(k, { from: r.from, n: 0, a: r.pts[0], b: r.pts[1] });
      exits.get(k).n++;
    }
    for (const e of exits.values()) if (e.n >= 4) badges.push({ from: e.from, n: e.n, x: (e.a[0] + e.b[0]) / 2, y: (e.a[1] + e.b[1]) / 2 });
    const maxUsed = Math.max(0, ...[...cell.values()].map((p) => p.c)) + 1;
    const W = Math.max(Math.min(avail, 440), gapC[maxUsed] + vw[maxUsed] / 2 + g.pad);
    const H = Math.max(prev ? prev.y + prev.w / 2 : y, ...sides.map((s) => s.y1 + 10)) + g.pad / 2;
    const counts = new Map([...tracks].map(([key, l]) => [key, l.length]));
    return { g, W, H, cols, box, routes, badges, lanes: laneList.map((l) => {
      const cs = l.nodes.map((n) => cell.get(n.id).c);
      return { key: l.key, x0: colX[Math.min(...cs)] - 12, x1: colX[Math.max(...cs)] + g.w + 12, y0: l.shelf.y0, y1: l.shelf.y1 };
    }), sides, counts, width };
  }
}

// ---------- HTML ----------

const CSS = `
:root{--bg:#fbfbfa;--fg:#1d1f23;--muted:#666b73;--line:#d9dbe0;--panel:#ffffff;--node:#ffffff;--outside:#f1efe8;--sender:#ece9f7;
--edge:#8b919b;--accent:#b4400f;--accent2:#1f6fb2;--new:#0f8a4b;--bad:#c0261d;--lane:#f2f3f5;--shadow:0 1px 2px rgba(0,0,0,.08)}
@media (prefers-color-scheme:dark){:root{--bg:#15171a;--fg:#e6e7ea;--muted:#9aa0a9;--line:#33373e;--panel:#1c1f23;--node:#22262b;
--outside:#2a2823;--sender:#28253a;--edge:#7d838d;--accent:#f08a4b;--accent2:#6aaef0;--new:#44c983;--bad:#f2665c;--lane:#1a1d21;--shadow:none}}
*{box-sizing:border-box}html,body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.4 system-ui,-apple-system,Segoe UI,sans-serif}
header{padding:12px 16px 4px}h1{font-size:17px;margin:0 0 2px}header p{margin:0;color:var(--muted);font-size:12.5px}
.bar{display:flex;flex-wrap:wrap;gap:8px;align-items:center;padding:8px 16px;border-bottom:1px solid var(--line);position:sticky;top:0;background:var(--bg);z-index:2}
button,.tab{font:inherit;color:inherit;background:var(--panel);border:1px solid var(--line);border-radius:6px;padding:4px 10px;cursor:pointer}
button:focus-visible,input:focus-visible{outline:2px solid var(--accent2);outline-offset:1px}
.tab[aria-selected=true]{border-color:var(--fg);font-weight:600}
#count{font-variant-numeric:tabular-nums;min-width:5.5em;text-align:center}
#scrubwrap{flex:1 1 160px;min-width:120px;display:flex;flex-direction:column;gap:2px}#scrub{width:100%;margin:0}
#sections{display:flex;gap:2px;height:15px}.sec{flex:1 1 0;min-width:3px;padding:0 4px;font-size:10px;line-height:15px;overflow:hidden;white-space:nowrap;text-overflow:ellipsis;border-radius:3px;background:var(--lane);border:0;color:var(--muted);text-align:left}
.sec.cur{background:var(--accent2);color:var(--bg)}
main.nopanel #panel{display:none}#paneltoggle[aria-pressed=false]{opacity:.7}
#legend{padding:0 16px 4px;font-size:12px;color:var(--muted)}#legend summary{cursor:pointer;width:max-content}
ul.changes{margin:4px 0 8px;padding-left:16px}ul.changes li{margin:2px 0}ul.changes ul{padding-left:14px}#panel a{color:inherit;text-decoration:none;border-bottom:1px dotted var(--muted)}
label.chk{display:flex;gap:4px;align-items:center;font-size:13px}
#stepinfo{padding:6px 16px;font-size:13px;color:var(--muted);min-height:2.2em}
#stepinfo b{color:var(--fg)}.rev{color:var(--bad);font-weight:600}
main{display:flex;gap:0;align-items:stretch}
#mapwrap{flex:1 1 auto;overflow:auto;min-height:420px;max-height:calc(100vh - 150px)}
#panel{flex:0 0 340px;border-left:1px solid var(--line);background:var(--panel);padding:12px 14px;overflow:auto;max-height:calc(100vh - 150px);font-size:13px}
#panel h2{font-size:14px;margin:0 0 6px}#panel h3{font-size:13px;margin:12px 0 4px}
#panel .tx{border-top:1px solid var(--line);padding:6px 0}#panel code,td code{font:12px ui-monospace,SFMono-Regular,Menlo,monospace;word-break:break-all}
.muted{color:var(--muted)}.pill{display:inline-block;font-size:11px;padding:0 6px;border-radius:9px;border:1px solid var(--line);margin-right:4px}
.pill.ctl{border-color:var(--accent);color:var(--accent)}.pill.bad{border-color:var(--bad);color:var(--bad)}.pill.ok{border-color:var(--new);color:var(--new)}
svg{display:block}svg text{fill:var(--fg);font-size:12px}
.lane rect{fill:var(--lane)}.lane text{fill:var(--muted);font-size:11.5px;font-weight:600}
.node rect{fill:var(--node);stroke:var(--line);stroke-width:1.2;filter:drop-shadow(var(--shadow))}
.node.outside rect{fill:var(--outside);stroke-dasharray:4 3}.node.sender rect{fill:var(--sender);stroke-dasharray:4 3}
.node.outside-contract rect{fill:var(--outside)}
.node .addr{fill:var(--muted);font:11px ui-monospace,Menlo,monospace}
.node.ctl rect{stroke:var(--accent);stroke-width:2}.node .mark{fill:var(--accent);font-weight:700}
.node.cert .cert{fill:var(--new)}
.node{cursor:pointer;transition:opacity .15s}.node.future{opacity:.18}.node.future rect{stroke-dasharray:2 3}
.node.now rect{stroke:var(--new);stroke-width:3}.node.revnow rect{stroke:var(--bad);stroke-width:3}
.node.sel rect{stroke:var(--accent2);stroke-width:3}
.edge path{fill:none;stroke:var(--edge);stroke-width:1.3;opacity:.75}.edge.created path{stroke-dasharray:1 3;stroke-linecap:round}
.edge.call path{stroke-dasharray:6 3}.edge.verified path{stroke-dasharray:none;stroke-width:2}
.lens .edge path{opacity:.45}.lens .edge.ctl path{opacity:1;stroke:var(--accent);stroke-width:2}
.elabel{font-size:11px;fill:var(--fg);paint-order:stroke;stroke:var(--bg);stroke-width:4px;stroke-linejoin:round;display:none;pointer-events:none}
.elabel.shown{display:block}
.edge.now path{stroke:var(--new);stroke-width:2.6;opacity:1}.edge.future{display:none}
.edge.hot path{opacity:1;stroke-width:2.4}.edge{cursor:pointer}.edge path.hit{stroke:transparent;stroke-width:10;opacity:0}
.edge path{stroke-linejoin:round}
.badge circle{fill:var(--panel);stroke:var(--edge)}.badge.future{opacity:.18}.badge text{font-size:10px;font-weight:600}
.node .chain{fill:var(--muted);font-size:10px}
.lane text{paint-order:stroke;stroke:var(--lane);stroke-width:4px;stroke-linejoin:round}
.dim .node:not(.hot){opacity:.15}.dim .edge:not(.hot){opacity:.08}.dim .badge{opacity:.15}
@keyframes pop{0%{transform:scale(.6)}60%{transform:scale(1.08)}100%{transform:scale(1)}}
.anim .node.now>g{animation:pop .35s ease-out;transform-box:fill-box;transform-origin:center}
@media (prefers-reduced-motion:reduce){.anim .node.now>g{animation:none}.node{transition:none}}
#tableview{padding:0 16px 24px;overflow:auto}#tableview input{font:inherit;padding:4px 8px;margin:8px 0;width:min(420px,100%);border:1px solid var(--line);border-radius:6px;background:var(--panel);color:var(--fg)}
table{border-collapse:collapse;width:100%;font-size:12.5px}th,td{text-align:left;vertical-align:top;border-bottom:1px solid var(--line);padding:5px 6px}
th{position:sticky;top:0;background:var(--bg)}tr.reverted td{color:var(--bad)}
.legend{display:flex;flex-wrap:wrap;gap:10px;padding:4px 0 6px}
.legend svg{display:inline-block;vertical-align:middle}
.hidden{display:none!important}
@media (max-width:760px){main{flex-direction:column}#panel{flex:none;border-left:0;border-top:1px solid var(--line);max-height:none}#mapwrap{max-height:70vh}}
@media print{.bar,#mapwrap,#panel,#legend,#stepinfo{display:none!important}#tableview{display:block!important}}
`;

function client(place) {
  const D = JSON.parse(document.getElementById('data').textContent);
  const G = D.geom;
  const $ = (s) => document.querySelector(s);
  const esc = (s) => String(s ?? '').replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);
  const short = (a) => (a ? a.slice(0, 6) + '…' + a.slice(-4) : '');
  const cut = (s, n) => (String(s).length > n ? String(s).slice(0, n - 1) + '…' : String(s));
  const clip = (s, n = 90) => (String(s).length > n ? String(s).slice(0, n) + `… (${String(s).length} chars)` : String(s));
  const byId = new Map(D.nodes.map((n) => [n.id, n]));
  const title = (n) => n.role || n.name || n.label || { sender: 'deployer', outside: 'outside address', 'outside-contract': 'outside contract' }[n.kind] || 'unnamed';
  const kindText = { contract: 'created here', sender: 'sender (EOA)', outside: 'outside address: an EOA, multisig or contract', 'outside-contract': 'outside contract' };
  const NS = 'http://www.w3.org/2000/svg';
  const el = (tag, attrs, parent) => {
    const e = document.createElementNS(NS, tag);
    for (const k in attrs) e.setAttribute(k, attrs[k]);
    if (parent) parent.appendChild(e);
    return e;
  };

  const view = $('#mapwrap');
  const svg = el('svg', { role: 'img', 'aria-label': 'Deployment map; the table view lists the same transactions' });
  view.appendChild(svg);
  const nodeEls = new Map(), edgeEls = new Map();
  const multiChain = new Set(D.nodes.map((n) => n.chain)).size > 1;
  const laneName = (k) => {
    const [chain, s] = k.split('|');
    return `chain ${chain} · ${s}`;
  };
  const rounded = (pts) => {
    let d = `M${pts[0][0]},${pts[0][1]}`;
    for (let i = 1; i < pts.length - 1; i++) {
      const [px, py] = pts[i - 1], [x, y] = pts[i], [nx, ny] = pts[i + 1];
      const r = Math.min(6, Math.hypot(x - px, y - py) / 2, Math.hypot(nx - x, ny - y) / 2);
      const ax = x - Math.sign(x - px) * r, ay = y - Math.sign(y - py) * r, bx = x + Math.sign(nx - x) * r, by = y + Math.sign(ny - y) * r;
      d += ` L${ax},${ay} Q${x},${y} ${bx},${by}`;
    }
    return d + ` L${pts[pts.length - 1][0]},${pts[pts.length - 1][1]}`;
  };

  let L;
  function draw() {
    L = place(D, G, view.clientWidth || 1000);
    const g = L.g;
    svg.setAttribute('viewBox', `0 0 ${L.W} ${L.H}`);
    svg.setAttribute('width', L.W);
    svg.setAttribute('height', L.H);
    svg.replaceChildren();
    nodeEls.clear();
    edgeEls.clear();
    const defs = el('defs', {}, svg);
    for (const [id, color] of [['arr', 'var(--edge)'], ['arrc', 'var(--accent)']]) {
      const m = el('marker', { id, viewBox: '0 0 10 10', refX: 9, refY: 5, markerWidth: 7, markerHeight: 7, orient: 'auto-start-reverse' }, defs);
      el('path', { d: 'M0,0 L10,5 L0,10 z', fill: color }, m);
    }
    const lanesG = el('g', {}, svg), edgesG = el('g', {}, svg), nodesG = el('g', {}, svg), labelsG = el('g', {}, svg);
    for (const l of L.lanes) {
      const lg = el('g', { class: 'lane' }, lanesG);
      el('rect', { x: l.x0, y: l.y0, width: l.x1 - l.x0, height: l.y1 - l.y0, rx: 8 }, lg);
      el('text', { x: l.x0 + 10, y: l.y0 + 17 }, lg).textContent = laneName(l.key);
    }
    for (const s of L.sides) {
      const lg = el('g', { class: 'lane side' }, lanesG);
      el('rect', { x: g.pad - 8, y: s.y0, width: g.w + 16, height: s.y1 - s.y0, rx: 8 }, lg);
      el('text', { x: g.pad, y: s.y0 + 17 }, lg).textContent = `chain ${s.chain} · shared outside`;
    }

    for (const n of D.nodes) {
      const p = L.box.get(n.id);
      const cls = ['node', n.kind];
      if (n.certified) cls.push('cert');
      const ng = el('g', { class: cls.join(' '), tabindex: 0, role: 'button', 'aria-label': `${title(n)} ${n.addr}` }, nodesG);
      const inner = el('g', { transform: `translate(${p.x},${p.y})` }, ng);
      el('rect', { width: g.w, height: g.h, rx: 7 }, inner);
      const room = Math.floor((g.w - 14 - (multiChain ? String(n.chain).length * 6 + 6 : 0)) / 7.2);
      el('text', { x: 9, y: 18 }, inner).textContent = cut(title(n), room);
      const marks = (n.controlledBy ? 2 : 0) + (n.certified ? 2 : 0);
      el('text', { x: 9, y: 35, class: 'addr' }, inner).textContent = short(n.addr) + (n.role && n.name ? ' · ' + cut(n.name, Math.floor(g.w / 7.2) - 14 - marks) : '');
      if (multiChain) el('text', { x: g.w - 7, y: 15, class: 'chain', 'text-anchor': 'end' }, inner).textContent = n.chain;
      if (n.controlledBy) {
        const m = el('text', { x: g.w - (n.certified ? 30 : 16), y: 36, class: 'mark' }, inner);
        m.textContent = '⚑';
        el('title', {}, m).textContent = 'controlled by an outside address';
      }
      if (n.certified) el('text', { x: g.w - 16, y: 36, class: 'cert' }, inner).textContent = '✓';
      el('title', {}, ng).textContent = `${title(n)}\n${n.addr}\nchain ${n.chain} · ${kindText[n.kind]}`;
      ng.addEventListener('mouseenter', () => hover({ node: n.id }));
      ng.addEventListener('mouseleave', () => hover(null));
      ng.addEventListener('click', (e) => { e.stopPropagation(); select({ node: n.id }); });
      ng.addEventListener('keydown', (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); select({ node: n.id }); } });
      nodeEls.set(n.id, ng);
    }

    // One drawn link per ordered pair; its style is its strongest edge's.
    const rank = { deploy: 2, call: 1, created: 0 };
    for (const r of [...L.routes].sort((a, b) => a.edges.some((e) => e.rule) - b.edges.some((e) => e.rule))) {
      const kind = r.edges.reduce((a, e) => (rank[e.kind] > rank[a] ? e.kind : a), r.edges[0].kind);
      const ctl = r.edges.some((e) => e.rule);
      const cls = ['edge', kind];
      if (ctl) cls.push('ctl');
      if (D.sprue && r.edges.some((e) => e.verified)) cls.push('verified');
      const eg = el('g', { class: cls.join(' ') }, edgesG);
      const d = rounded(r.pts);
      el('path', { d, 'marker-end': ctl ? 'url(#arrc)' : 'url(#arr)' }, eg);
      el('path', { d, class: 'hit' }, eg);
      const text = r.edges.length === 1 ? r.edges[0].label + (r.edges[0].rule ? ` [${r.edges[0].rule}]` : '') : `${r.edges.length} links: ${r.edges.map((e) => e.label).join(', ')}`;
      const lt = el('text', { x: r.labelAt[0], y: r.labelAt[1] - 3, 'text-anchor': 'middle', class: 'elabel' }, labelsG);
      lt.textContent = cut(text, 46);
      el('title', {}, eg).textContent = `${title(byId.get(r.from))} → ${title(byId.get(r.to))}\n${r.edges.map((e) => e.label + (e.rule ? ` (rule ${e.rule})` : '') + (e.verified ? ' (certificate-verified)' : '')).join('\n')}`;
      eg.addEventListener('mouseenter', () => hover({ link: r.key }));
      eg.addEventListener('mouseleave', () => hover(null));
      eg.addEventListener('click', (ev) => { ev.stopPropagation(); select({ link: r.key }); });
      edgeEls.set(r.key, { g: eg, label: lt, r, firstStep: Math.min(...r.edges.map((e) => e.firstStep)) });
    }
    for (const b of L.badges) {
      const bg = el('g', { class: 'badge', 'data-node': b.to || b.from }, labelsG);
      el('circle', { cx: b.x, cy: b.y, r: 8 }, bg);
      el('text', { x: b.x, y: b.y + 3.5, 'text-anchor': 'middle' }, bg).textContent = b.n;
      el('title', {}, bg).textContent = b.to ? `${b.n} links merge here into ${title(byId.get(b.to))}` : `${b.n} links leave ${title(byId.get(b.from))} here as one bus`;
    }
  }

  // The page opens on the whole deployment; a step's marks appear once the reader moves.
  const S = { step: D.steps.length - 1, sel: null, lens: true, moved: false };
  const scrub = $('#scrub');
  scrub.max = D.steps.length - 1;

  function txLine(i, detail) {
    const x = D.txs[i];
    const tgt = byId.get(`${x.chain}:${x.to}`);
    const args = x.args.map((a) => `${esc(a.name)} = <code>${esc(clip(a.value))}</code>`).join('<br>');
    return `<div class="tx"><b>step ${x.step + 1}</b> ${x.type === 'CALL' ? esc(x.fn || '(no data)') : esc(x.type) + ' ' + esc(x.contractName || '')}
      ${x.status === 'reverted' ? '<span class="pill bad">reverted</span>' : x.status === 'unknown' ? '<span class="pill">no receipt</span>' : ''}
      ${x.decode === 'raw' ? '<span class="pill">selector only</span>' : x.decode === 'failed' ? '<span class="pill bad">undecoded</span>' : ''}
      <div class="muted">to ${tgt ? esc(title(tgt)) : ''} <code>${esc(x.to || '')}</code> · from <code>${esc(short(x.from))}</code></div>
      ${detail && !x.args.some((a) => detail === `${a.name} = ${String(a.value).toLowerCase()}`) ? `<div>link: ${esc(detail)}</div>` : ''}${args ? `<div>${args}</div>` : ''}
      <div class="muted">${x.block !== null ? 'block ' + x.block + ' · ' : ''}${x.sig ? esc(x.sig) + ' · ' : ''}<code>${esc(x.hash || 'no hash')}</code></div></div>`;
  }
  function linkBlock(key) {
    const { r } = edgeEls.get(key);
    return r.edges.map(edgeBlock).join('');
  }
  function edgeBlock(e) {
    const a = byId.get(e.from), b = byId.get(e.to);
    return `<h3>${esc(title(a))} → ${esc(title(b))}</h3><div>${{ deploy: 'set at deploy', call: 'set by call', created: 'created by' }[e.kind]}: <code>${esc(e.label)}</code>
      ${e.rule ? `<span class="pill ctl">${esc(e.rule)}</span>` : ''}${D.sprue ? (e.verified ? '<span class="pill ok">certificate-verified</span>' : '<span class="pill">not certified</span>') : ''}
      ${e.decoded ? '' : '<span class="pill bad">found in raw calldata</span>'}</div>${e.txs.map((d) => txLine(d.i, d.detail)).join('')}`;
  }
  function panel() {
    const P = $('#panel');
    if (S.sel && S.sel.node) {
      const n = byId.get(S.sel.node);
      const es = D.edges.filter((e) => e.from === n.id || e.to === n.id);
      const made = D.txs.find((x) => x.created.includes(n.id));
      P.innerHTML = `<h2>${esc(title(n))}</h2><div><code>${esc(n.addr)}</code></div><div class="muted">chain ${n.chain} · ${esc(kindText[n.kind])}${n.name && n.role ? ' · ' + esc(n.name) : ''}</div>
        ${n.certified ? '<div><span class="pill ok">certified in its journal</span></div>' : ''}
        ${n.controlledBy ? `<div><span class="pill ctl">controlled by an outside address</span> ${n.controlledBy.map((c) => esc(title(byId.get(c.by))) + ' (' + esc(c.rule) + ')').join(', ')}</div>` : ''}
        ${made ? `<h3>Created</h3>${txLine(made.i)}` : ''}${es.length ? es.map(edgeBlock).join('') : '<p class="muted">No links.</p>'}`;
    } else if (S.sel && S.sel.link) {
      P.innerHTML = linkBlock(S.sel.link);
    } else {
      const s = D.stats;
      P.innerHTML = `<h2>Deployment</h2><p>${s.contracts} contracts created, ${s.nodes - s.contracts} outside addresses, ${s.edges} links (${s.control} matched a control rule), ${s.steps} steps${s.reverted ? `, ${s.reverted} reverted` : ''}.</p>
        ${D.warnings.map((w) => `<p class="rev">${esc(w)}</p>`).join('')}
        <h3>Step ${S.step + 1}: what changed</h3>${stepChanges(S.step)}
        <h3>Who controls what</h3>${controls()}
        <p class="muted">Control is read from function and parameter names (the rule is shown), so it is a heuristic. Select a line, an address or a link for the transactions behind it.</p>`;
    }
  }
  const nameOf = (id) => esc(title(byId.get(id)));
  const linkKey = (e) => e.from + '>' + e.to;
  // One line per change, newest state first: what the step created, then each link it set.
  function stepChanges(k) {
    const lines = [];
    for (const i of D.steps[k].txs) {
      const x = D.txs[i];
      if (x.status === 'reverted') lines.push(`<li class="rev">${esc(x.fn || x.type)} reverted: nothing created or bound</li>`);
      for (const id of x.created) lines.push(`<li><a href="#" data-node="${esc(id)}">+ ${nameOf(id)}</a> created</li>`);
      for (const e of D.edges)
        if (e.kind !== 'created' && e.txs.some((d) => d.i === i))
          lines.push(`<li><a href="#" data-link="${esc(linkKey(e))}">${nameOf(e.from)} · ${esc(e.label)} → ${nameOf(e.to)}</a>${e.rule ? ` <span class="pill ctl">${esc(e.rule)}</span>` : ''}</li>`);
      if (!x.created.length && !D.edges.some((e) => e.txs.some((d) => d.i === i)) && x.status !== 'reverted')
        lines.push(`<li class="muted">${esc(x.fn || x.type)} on ${nameOf(`${x.chain}:${x.to}`)}: no link</li>`);
    }
    const seen = new Map();
    for (const l of lines) seen.set(l, (seen.get(l) || 0) + 1);
    return `<ul class="changes">${[...seen].map(([l, n]) => (n > 1 ? l.replace(/<\/li>$/, ` ×${n}</li>`) : l)).join('')}</ul>`;
  }
  // The handover question: each address that a control rule points at, and what it holds; outside addresses first.
  function controls() {
    const by = new Map();
    for (const e of D.edges) if (e.rule) (by.get(e.to) || by.set(e.to, []).get(e.to)).push(e);
    if (!by.size) return '<p class="muted">No link matched a control rule.</p>';
    const order = [...by.keys()].sort((a, b) => (byId.get(a).kind === 'contract') - (byId.get(b).kind === 'contract'));
    return `<ul class="changes">${order.map((id) => `<li><a href="#" data-node="${esc(id)}"><b>${nameOf(id)}</b></a> <code>${esc(short(byId.get(id).addr))}</code>${multiChain ? ` <span class="muted">chain ${byId.get(id).chain}</span>` : ''}${byId.get(id).kind === 'contract' ? '' : ' <span class="pill">outside</span>'}<ul>${by.get(id).map((e) => `<li><a href="#" data-link="${esc(linkKey(e))}">${nameOf(e.from)} · ${esc(e.label)}</a> <span class="muted">step ${e.firstStep + 1}</span></li>`).join('')}</ul></li>`).join('')}</ul>`;
  }
  function hover(focus) {
    if (!focus && S.sel) return apply();
    apply(focus);
  }
  function select(sel) {
    S.sel = sel && S.sel && JSON.stringify(sel) === JSON.stringify(S.sel) ? null : sel;
    apply();
    panel();
  }

  function apply(focus = S.sel) {
    const s = S.step, last = s === D.steps.length - 1;
    svg.classList.toggle('lens', S.lens && D.edges.some((e) => e.rule));
    const stepTx = new Set(D.steps[s].txs);
    const reverted = D.steps[s].txs.filter((i) => D.txs[i].status === 'reverted');
    for (const n of D.nodes) {
      const g = nodeEls.get(n.id);
      g.classList.toggle('future', n.firstStep > s);
      g.classList.toggle('now', S.moved && n.createdStep === s);
      g.classList.toggle('revnow', reverted.some((i) => `${D.txs[i].chain}:${D.txs[i].to}` === n.id));
      g.classList.toggle('sel', !!(S.sel && S.sel.node === n.id));
      g.classList.toggle('ctl', !!n.controlledBy && S.lens);
      g.classList.remove('hot');
    }
    for (const { g, label, r, firstStep } of edgeEls.values()) {
      const now = S.moved && r.edges.some((e) => e.txs.some((d) => stepTx.has(d.i)));
      for (const x of [g, label]) {
        x.classList.toggle('future', firstStep > s);
        x.classList.toggle('now', now);
        x.classList.remove('hot');
      }
    }
    svg.classList.toggle('dim', !!focus);
    if (focus) {
      const hot = new Set();
      for (const { g, label, r } of edgeEls.values())
        if (focus.link === r.key || r.from === focus.node || r.to === focus.node) {
          g.classList.add('hot');
          label.classList.add('hot');
          g.parentNode.appendChild(g);
          hot.add(r.from).add(r.to);
        }
      if (focus.node) hot.add(focus.node);
      for (const id of hot) nodeEls.get(id)?.classList.add('hot');
    }
    svg.querySelectorAll('.badge').forEach((b) => b.classList.toggle('future', byId.get(b.dataset.node).firstStep > s));
    placeLabels(focus);
    document.querySelectorAll('.sec').forEach((b, k) => b.classList.toggle('cur', k === secOf(s)));
    $('#count').textContent = `${s + 1}/${D.steps.length}`;
    scrub.value = s;
    scrub.setAttribute('aria-valuetext', `step ${s + 1} of ${D.steps.length}`);
    $('#prev').disabled = s === 0;
    $('#next').disabled = last;
    const st = D.steps[s];
    const parts = st.txs.map((i) => {
      const x = D.txs[i];
      const what = x.type === 'CALL' ? `<b>${esc(x.fn || '(no data)')}</b> on ${esc(title(byId.get(`${x.chain}:${x.to}`) || {}))}` : `<b>${esc(x.type)}</b> ${esc(x.contractName || '')}`;
      const made = x.created.length ? ` · creates ${x.created.map((id) => esc(title(byId.get(id)))).join(', ')}` : '';
      const binds = D.edges.filter((e) => e.kind !== 'created' && e.txs.some((d) => d.i === i)).length;
      return `${what}${made}${binds ? ` · binds ${binds} link${binds > 1 ? 's' : ''}` : ''}${x.status === 'reverted' ? ' · <span class="rev">reverted: created and bound nothing</span>' : ''}`;
    });
    $('#stepinfo').innerHTML = `${st.id ? `<b>${esc(st.id)}</b> · ` : ''}${esc(D.txs[st.txs[0]].script)} · ${parts.join('<br>')}`;
  }

  // Labels of the focused links, else of the current step's, each at the first spot along its route that
  // overlaps no box and no other label; one that fits nowhere stays in the side panel only.
  function placeLabels(focus) {
    const g = L.g, taken = [...L.box.values()].map((b) => [b.x, b.y, b.x + g.w, b.y + g.h]).concat(L.badges.map((b) => [b.x - 9, b.y - 9, b.x + 9, b.y + 9]));
    const free = (r) => r[0] >= 0 && r[2] <= L.W && taken.every((t) => r[2] <= t[0] || r[0] >= t[2] || r[3] <= t[1] || r[1] >= t[3]);
    for (const x of edgeEls.values()) {
      const want = focus ? x.g.classList.contains('hot') : x.label.classList.contains('now') && !x.label.classList.contains('future');
      x.label.classList.remove('shown');
      if (!want) continue;
      const w = x.label.textContent.length * 6.2 + 6, h = 14, pts = x.r.pts;
      let spot = null;
      for (const t of [0.5, 0.3, 0.7, 0.15, 0.85]) {
        for (let i = 1; i < pts.length && !spot; i++) {
          const [x1, y1] = pts[i - 1], [x2, y2] = pts[i];
          const px = x1 + (x2 - x1) * t, py = y1 + (y2 - y1) * t;
          const cands = y1 === y2 ? [[px, py - 4], [px, py + 13]] : [[px + w / 2 + 4, py + 4], [px - w / 2 - 4, py + 4]];
          for (const [cx, cy] of cands) {
            const r = [cx - w / 2, cy - 11, cx + w / 2, cy - 11 + h];
            if (free(r)) { spot = [cx, cy, r]; break; }
          }
        }
        if (spot) break;
      }
      if (!spot) continue;
      x.label.setAttribute('x', spot[0]);
      x.label.setAttribute('y', spot[1]);
      x.label.classList.add('shown');
      taken.push(spot[2]);
    }
  }

  const go = (s) => {
    S.step = Math.max(0, Math.min(D.steps.length - 1, s));
    S.moved = true;
    svg.classList.add('anim');
    apply();
    if (!S.sel) panel();
  };
  // Sections: runs of steps from one script, or one sprue unit.
  const sections = [];
  D.steps.forEach((st, k) => {
    const name = D.sprue && st.id ? st.id.split('.')[0] : D.txs[st.txs[0]].script;
    const last = sections[sections.length - 1];
    if (last && last.name === name) last.end = k;
    else sections.push({ name, start: k, end: k });
  });
  const secOf = (k) => sections.findIndex((x) => k >= x.start && k <= x.end);
  $('#sections').append(...sections.map((x) => {
    const b = document.createElement('button');
    b.className = 'sec';
    b.style.flexGrow = x.end - x.start + 1;
    b.textContent = x.name;
    b.title = `${x.name}: steps ${x.start + 1}–${x.end + 1}`;
    b.onclick = () => go(x.start);
    return b;
  }));
  $('#prev').onclick = () => go(S.step - 1);
  $('#next').onclick = () => go(S.step + 1);
  $('#first').onclick = () => go(0);
  $('#lastb').onclick = () => go(D.steps.length - 1);
  scrub.oninput = () => go(Number(scrub.value));
  $('#lens').onchange = (e) => { S.lens = e.target.checked; apply(); };
  let resizing;
  window.addEventListener('resize', () => {
    clearTimeout(resizing);
    resizing = setTimeout(() => { draw(); apply(); }, 120);
  });
  svg.addEventListener('click', () => select(null));
  $('#panel').addEventListener('click', (e) => {
    const a = e.target.closest('a[data-node],a[data-link]');
    if (!a) return;
    e.preventDefault();
    select(a.dataset.node ? { node: a.dataset.node } : { link: a.dataset.link });
  });
  $('#paneltoggle').onclick = (e) => {
    const on = $('main').classList.toggle('nopanel');
    e.target.setAttribute('aria-pressed', String(!on));
    draw();
    apply();
  };
  if (window.innerWidth < 760) $('#legend').open = false;
  document.addEventListener('keydown', (e) => {
    if (e.target.tagName === 'INPUT' && e.target.type !== 'range' && e.target.type !== 'checkbox') return;
    if (e.key === 'ArrowRight') { go(S.step + 1); e.preventDefault(); }
    else if (e.key === 'ArrowLeft') { go(S.step - 1); e.preventDefault(); }
    else if (e.key === 'Home') { go(sections[secOf(S.step)].start); e.preventDefault(); }
    else if (e.key === 'End') { go(sections[secOf(S.step)].end); e.preventDefault(); }
    else if (e.key === 'PageUp') { const k = secOf(S.step); go(sections[S.step > sections[k].start ? k : Math.max(0, k - 1)].start); e.preventDefault(); }
    else if (e.key === 'PageDown') { go(sections[Math.min(sections.length - 1, secOf(S.step) + 1)].start); e.preventDefault(); }
    else if (e.key === 'Escape') select(null);
  });

  // Table.
  const rows = D.txs.map((x) => {
    const tgt = byId.get(`${x.chain}:${x.to}`);
    const args = x.args.map((a) => `${esc(a.name)}: <code>${esc(clip(a.value, 120))}</code>`).join('<br>') || (x.decode === 'raw' ? `<span class="muted">selector ${esc(x.selector)}, ${x.bytes} bytes</span>` : '');
    const tr = document.createElement('tr');
    if (x.status === 'reverted') tr.className = 'reverted';
    tr.innerHTML = `<td>${x.step + 1}${D.steps[x.step].id ? `<br><span class="muted">${esc(D.steps[x.step].id)}</span>` : ''}</td><td>${esc(x.script)}<br><span class="muted">chain ${x.chain}</span></td>
      <td>${esc(x.type)}</td><td>${tgt ? esc(title(tgt)) : ''}<br><code>${esc(x.to || '')}</code></td><td><code>${esc(x.fn || '')}</code></td><td>${args}</td>
      <td>${esc(x.status)}${x.block !== null ? '<br>block ' + x.block : ''}</td><td><code>${esc(x.hash || '')}</code></td>`;
    tr.dataset.text = tr.textContent.toLowerCase();
    return tr;
  });
  $('#tbody').append(...rows);
  $('#filter').oninput = (e) => {
    const q = e.target.value.toLowerCase();
    for (const r of rows) r.classList.toggle('hidden', !!q && !r.dataset.text.includes(q));
  };
  const tabs = { map: $('#tab-map'), table: $('#tab-table') };
  const show = (which) => {
    tabs.map.setAttribute('aria-selected', which === 'map');
    tabs.table.setAttribute('aria-selected', which === 'table');
    $('#mapview').classList.toggle('hidden', which !== 'map');
    $('#tableview').classList.toggle('hidden', which !== 'table');
    for (const id of ['#playbar']) $(id).classList.toggle('hidden', which !== 'map');
  };
  tabs.map.onclick = () => show('map');
  tabs.table.onclick = () => show('table');
  draw();
  apply();
  panel();
}

export function render(model, title) {
  const data = JSON.stringify({ ...model, geom: GEOM }).replace(/</g, '\\u003c').replace(/[\u2028\u2029]/g, (c) => '\\u' + c.charCodeAt(0).toString(16));
  const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);
  const s = model.stats;
  const scripts = [...new Set(model.txs.map((x) => x.script))];
  const legend = `<details id="legend" open><summary>Legend</summary><div class="legend">
<span><svg width="28" height="10"><path d="M0,5 H28" stroke="var(--edge)" stroke-dasharray="1 3" stroke-linecap="round" stroke-width="1.5"/></svg> created by</span>
<span><svg width="28" height="10"><path d="M0,5 H28" stroke="var(--edge)" stroke-width="1.5"/></svg> set at deploy</span>
<span><svg width="28" height="10"><path d="M0,5 H28" stroke="var(--edge)" stroke-dasharray="6 3" stroke-width="1.5"/></svg> set by call</span>
<span><svg width="28" height="10"><path d="M0,5 H28" stroke="var(--accent)" stroke-width="2"/></svg> control rule matched</span>
<span>⚑ controlled by an outside address</span>${model.sprue ? '<span>✓ certified role; thick solid line: certificate-verified link</span>' : ''}
<span>dashed box: not created by this deployment</span><span>a number: links merging into one entry</span><span>labels show on hover, on selection and for the current step</span></div></details>`;
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light dark"><title>${esc(title)}</title><style>${CSS}</style></head>
<body><header><h1 title="${esc(scripts.join(', '))}">${esc(title)}</h1>${scripts.length > 1 ? `<p>Scripts: ${esc(scripts.join(', '))}.</p>` : ''}<p>${s.contracts} contracts, ${s.nodes - s.contracts} outside addresses, ${s.edges} links, ${s.steps} steps, from ${s.records} broadcast record files. Built offline from forge's records; links show what the records say, not what the chain holds now.</p></header>
<div class="bar" id="topbar"><button class="tab" id="tab-map" aria-selected="true">Map</button><button class="tab" id="tab-table" aria-selected="false">Table</button>
<span id="playbar" style="display:contents"><button id="first" aria-label="first step">⏮</button><button id="prev" aria-label="previous step">◀</button><span id="count" aria-live="polite"></span><button id="next" aria-label="next step">▶</button><button id="lastb" aria-label="last step">⏭</button>
<span id="scrubwrap"><input id="scrub" type="range" min="0" step="1" aria-label="step" title="Arrow keys: step; PageUp/PageDown: section; Home/End: section start/end"><span id="sections"></span></span><label class="chk"><input type="checkbox" id="lens" checked> control lens</label></span><button id="paneltoggle" aria-pressed="true" aria-controls="panel">Panel</button></div>
<div id="mapview"><div id="stepinfo" aria-live="polite"></div>${legend}<main><div id="mapwrap"></div><aside id="panel" aria-live="polite"></aside></main></div>
<section id="tableview" class="hidden"><input id="filter" type="search" placeholder="Filter transactions" aria-label="Filter transactions">
<table><caption class="muted" style="text-align:left">One row per transaction, in order.</caption><thead><tr><th>Step</th><th>Script</th><th>Type</th><th>Target</th><th>Function</th><th>Arguments</th><th>Status</th><th>Hash</th></tr></thead><tbody id="tbody"></tbody></table></section>
<script type="application/json" id="data">${data}</script>
<script>(${client.toString()})(${place.toString()});</script></body></html>
`;
}

// ---------- CLI ----------

function main(argv) {
  const paths = [];
  let project = null, sprue = null, title = null;
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--project') project = argv[++i];
    else if (a === '--sprue') {
      sprue = { dir: argv[++i], network: argv[++i] };
      if (!sprue.dir || !sprue.network) return fail('--sprue needs a project directory and a network name');
    } else if (a === '--title') title = argv[++i];
    else if (a === '-h' || a === '--help') { process.stdout.write(USAGE + '\n'); return 0; }
    else if (a.startsWith('-')) return fail(`unknown option ${a}`);
    else paths.push(a);
  }
  if (sprue) {
    project = project || sprue.dir;
    if (!paths.length) paths.push(join(sprue.dir, 'broadcast'));
  }
  if (!paths.length) return fail('name a broadcast directory or record files');
  for (const p of paths) if (!existsSync(p)) return fail(`${p} does not exist`);
  const model = build({ paths, project, sprue });
  if (!model.txs.length) return fail(`no broadcast records with transactions under ${paths.join(' ')}`);
  const scripts = [...new Set(model.txs.map((x) => x.script))];
  const more = scripts.length > 1 ? ` +${scripts.length - 1} script${scripts.length > 2 ? 's' : ''}` : '';
  process.stdout.write(render(model, title || `Deployment map: ${project ? `${basename(resolve(project))} (${scripts.length} script${scripts.length > 1 ? 's' : ''})` : scripts[0] + more}`));
  const s = model.stats;
  process.stderr.write(`deploy-map: ${s.nodes} nodes, ${s.edges} edges (${s.edgesDecoded} decoded, ${s.control} control), ${s.steps} steps, ${s.txs} transactions\n`);
  for (const w of model.warnings) process.stderr.write(`deploy-map: ${w}\n`);
  return 0;
}

function fail(msg) {
  process.stderr.write(`deploy-map: ${msg}\n${USAGE}\n`);
  return 2;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) process.exitCode = main(process.argv.slice(2));

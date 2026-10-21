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
export const GEOM = { w: 176, h: 46, gx: 44, gy: 34, laneGap: 52, cols: 5, pad: 24, title: 26 };

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
#scrub{flex:1 1 160px;min-width:120px}
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
.lens .edge path{opacity:.28}.lens .edge.ctl path{opacity:1;stroke:var(--accent);stroke-width:2}
.edge text{font-size:10.5px;fill:var(--muted);paint-order:stroke;stroke:var(--bg);stroke-width:3px;display:none}
.lens.few .edge.ctl text,.edge.hot text,.edge.now text{display:block}
.edge.now path{stroke:var(--new);stroke-width:2.6;opacity:1}.edge.future{display:none}
.edge.hot path{opacity:1;stroke-width:2.4}.edge{cursor:pointer}.edge path.hit{stroke:transparent;stroke-width:10;opacity:0}
.dim .node:not(.hot){opacity:.15}.dim .edge:not(.hot){opacity:.08}
@keyframes pop{0%{transform:scale(.6)}60%{transform:scale(1.08)}100%{transform:scale(1)}}
.anim .node.now>g{animation:pop .35s ease-out;transform-box:fill-box;transform-origin:center}
@media (prefers-reduced-motion:reduce){.anim .node.now>g{animation:none}.node{transition:none}}
#tableview{padding:0 16px 24px;overflow:auto}#tableview input{font:inherit;padding:4px 8px;margin:8px 0;width:min(420px,100%);border:1px solid var(--line);border-radius:6px;background:var(--panel);color:var(--fg)}
table{border-collapse:collapse;width:100%;font-size:12.5px}th,td{text-align:left;vertical-align:top;border-bottom:1px solid var(--line);padding:5px 6px}
th{position:sticky;top:0;background:var(--bg)}tr.reverted td{color:var(--bad)}
.legend{display:flex;flex-wrap:wrap;gap:10px;padding:4px 16px 8px;font-size:12px;color:var(--muted)}
.legend svg{display:inline-block;vertical-align:middle}
.hidden{display:none!important}
@media (max-width:760px){main{flex-direction:column}#panel{flex:none;border-left:0;border-top:1px solid var(--line);max-height:none}#mapwrap{max-height:70vh}}
@media print{.bar,#mapwrap,#panel,.legend,#stepinfo{display:none!important}#tableview{display:block!important}}
`;

function client() {
  const D = JSON.parse(document.getElementById('data').textContent);
  const G = D.geom;
  const $ = (s) => document.querySelector(s);
  const esc = (s) => String(s ?? '').replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);
  const short = (a) => (a ? a.slice(0, 6) + '…' + a.slice(-4) : '');
  const cut = (s, n) => (String(s).length > n ? String(s).slice(0, n - 1) + '…' : String(s));
  const clip = (s, n = 90) => (String(s).length > n ? String(s).slice(0, n) + `… (${String(s).length} chars)` : String(s));
  const byId = new Map(D.nodes.map((n) => [n.id, n]));
  const title = (n) => n.role || n.name || { sender: 'sender', outside: 'outside address', 'outside-contract': 'outside contract' }[n.kind] || 'unnamed';
  const kindText = { contract: 'created here', sender: 'sender (EOA)', outside: 'outside address: an EOA, multisig or contract', 'outside-contract': 'outside contract' };
  const NS = 'http://www.w3.org/2000/svg';
  const el = (tag, attrs, parent) => {
    const e = document.createElementNS(NS, tag);
    for (const k in attrs) e.setAttribute(k, attrs[k]);
    if (parent) parent.appendChild(e);
    return e;
  };

  // Layout: lanes per chain (outside addresses, then one per script), creation order left to right, wrapped to
  // the width at hand. Positions depend only on the whole deployment and the width, never on the step.
  const view = $('#mapwrap');
  const svg = el('svg', { role: 'img', 'aria-label': 'Deployment map; the table view lists the same transactions' });
  view.appendChild(svg);
  const nodeEls = new Map(), edgeEls = new Map();
  let g = G;
  const laneName = (k) => {
    const [chain, s] = k.split('|');
    return `chain ${chain} · ${s === 'outside' ? 'outside addresses and senders' : s}`;
  };

  function draw() {
    const avail = view.clientWidth || 1000;
    g = avail < 560 ? { ...G, w: 150, gx: 20, pad: 10 } : G;
    const cols = Math.max(1, Math.min(G.cols, Math.floor((avail - 2 * g.pad + g.gx) / (g.w + g.gx))));
    const pos = new Map();
    let y = g.pad;
    const lanes = [];
    for (const k of D.lanes) {
      const ns = D.nodes.filter((n) => n.laneKey === k).sort((a, b) => a.ord - b.ord);
      if (!ns.length) continue;
      y += g.title;
      ns.forEach((n, j) => pos.set(n.id, { x: g.pad + (j % cols) * (g.w + g.gx), y: y + Math.floor(j / cols) * (g.h + g.gy) }));
      const rows = Math.ceil(ns.length / cols);
      lanes.push({ k, y0: y - g.title, y1: y + rows * (g.h + g.gy) - g.gy + 10 });
      y += rows * (g.h + g.gy) - g.gy + g.laneGap;
    }
    const W = Math.max(Math.min(avail, 440), g.pad * 2 + Math.min(cols, Math.max(...D.lanes.map((k) => D.nodes.filter((n) => n.laneKey === k).length), 1)) * (g.w + g.gx) - g.gx);
    const H = y - g.laneGap + g.pad + 10;
    svg.setAttribute('viewBox', `0 0 ${W} ${H}`);
    svg.setAttribute('width', W);
    svg.setAttribute('height', H);
    svg.replaceChildren();
    nodeEls.clear();
    edgeEls.clear();
    const defs = el('defs', {}, svg);
    for (const [id, color] of [['arr', 'var(--edge)'], ['arrc', 'var(--accent)']]) {
      const m = el('marker', { id, viewBox: '0 0 10 10', refX: 9, refY: 5, markerWidth: 7, markerHeight: 7, orient: 'auto-start-reverse' }, defs);
      el('path', { d: 'M0,0 L10,5 L0,10 z', fill: color }, m);
    }
    const lanesG = el('g', {}, svg), edgesG = el('g', {}, svg), nodesG = el('g', {}, svg);
    for (const l of lanes) {
      const lg = el('g', { class: 'lane' }, lanesG);
      el('rect', { x: g.pad / 3, y: l.y0, width: W - (2 * g.pad) / 3, height: l.y1 - l.y0, rx: 8 }, lg);
      el('text', { x: g.pad / 3 + 10, y: l.y0 + 17 }, lg).textContent = laneName(l.k);
    }

    for (const n of D.nodes) {
      const p = pos.get(n.id);
      const cls = ['node', n.kind];
      if (n.certified) cls.push('cert');
      const ng = el('g', { class: cls.join(' '), tabindex: 0, role: 'button', 'aria-label': `${title(n)} ${n.addr}` }, nodesG);
      const inner = el('g', { transform: `translate(${p.x},${p.y})` }, ng);
      el('rect', { width: g.w, height: g.h, rx: 7 }, inner);
      const room = Math.floor(g.w / 7.4) - (n.controlledBy || n.certified ? 2 : 0);
      el('text', { x: 9, y: 18 }, inner).textContent = cut(title(n), room);
      el('text', { x: 9, y: 35, class: 'addr' }, inner).textContent = short(n.addr) + (n.role && n.name ? ' · ' + cut(n.name, room - 14) : '');
      if (n.controlledBy) {
        const m = el('text', { x: g.w - 16, y: 18, class: 'mark' }, inner);
        m.textContent = '⚑';
        el('title', {}, m).textContent = 'controlled by an outside address';
      }
      if (n.certified) el('text', { x: g.w - 16, y: 36, class: 'cert' }, inner).textContent = '✓';
      el('title', {}, ng).textContent = `${title(n)}\n${n.addr}\n${kindText[n.kind]}`;
      ng.addEventListener('mouseenter', () => hover(n.id));
      ng.addEventListener('mouseleave', () => hover(null));
      ng.addEventListener('click', (e) => { e.stopPropagation(); select({ node: n.id }); });
      ng.addEventListener('keydown', (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); select({ node: n.id }); } });
      nodeEls.set(n.id, ng);
    }

    // Edges leave from the side of the box facing the other end; parallel edges between one pair fan out.
    const pairCount = new Map();
    const order = [...D.edges].sort((a, b) => (a.rule ? 1 : 0) - (b.rule ? 1 : 0));
    const port = (p, tx, ty) => {
      const cx = p.x + g.w / 2, cy = p.y + g.h / 2, dx = tx - cx, dy = ty - cy;
      if (Math.abs(dy) * g.w > Math.abs(dx) * g.h) return [cx + (dx * (g.h / 2)) / Math.abs(dy || 1), cy + Math.sign(dy) * (g.h / 2)];
      return [cx + Math.sign(dx) * (g.w / 2), cy + (dy * (g.w / 2)) / Math.abs(dx || 1)];
    };
    for (const e of order) {
      const a = pos.get(e.from), b = pos.get(e.to);
      if (!a || !b) continue;
      const pk = [e.from, e.to].sort().join('>');
      const k = pairCount.get(pk) || 0;
      pairCount.set(pk, k + 1);
      const [x1, y1] = port(a, b.x + g.w / 2, b.y + g.h / 2), [x2, y2] = port(b, a.x + g.w / 2, a.y + g.h / 2);
      const mx = (x1 + x2) / 2, my = (y1 + y2) / 2, len = Math.hypot(x2 - x1, y2 - y1) || 1;
      const bend = 18 + 16 * k + (Math.abs(y2 - y1) < 4 || Math.abs(x2 - x1) < 4 ? 26 : 0);
      const cx = mx + (-(y2 - y1) / len) * bend, cy = my + ((x2 - x1) / len) * bend;
      const cls = ['edge', e.kind];
      if (e.rule) cls.push('ctl');
      if (D.sprue && e.verified) cls.push('verified');
      const eg = el('g', { class: cls.join(' ') }, edgesG);
      const d = `M${x1},${y1} Q${cx},${cy} ${x2},${y2}`;
      el('path', { d, 'marker-end': e.rule ? 'url(#arrc)' : 'url(#arr)' }, eg);
      el('path', { d, class: 'hit' }, eg);
      el('text', { x: Math.min(W - 110, Math.max(110, (x1 + 2 * cx + x2) / 4)), y: (y1 + 2 * cy + y2) / 4, 'text-anchor': 'middle' }, eg).textContent =
        cut(e.label, 34) + (e.rule ? ` [${e.rule}]` : '');
      el('title', {}, eg).textContent = `${e.label}${e.rule ? `\ncontrol rule: ${e.rule}` : ''}${e.verified ? '\ncertificate-verified' : ''}`;
      eg.addEventListener('mouseenter', () => hover(null, e.id));
      eg.addEventListener('mouseleave', () => hover(null));
      eg.addEventListener('click', (ev) => { ev.stopPropagation(); select({ edge: e.id }); });
      edgeEls.set(e.id, { g: eg, e });
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
    } else if (S.sel && S.sel.edge) {
      P.innerHTML = edgeBlock(D.edges.find((e) => e.id === S.sel.edge));
    } else {
      const s = D.stats;
      P.innerHTML = `<h2>Deployment</h2><p>${s.contracts} contracts created, ${s.nodes - s.contracts} outside addresses, ${s.edges} links (${s.control} matched a control rule), ${s.steps} steps${s.reverted ? `, ${s.reverted} reverted` : ''}.</p>
        <p class="muted">Hover or select an address to see its links and the transactions behind each one. The control lens draws links whose function or parameter name suggests control; the rule that matched is shown. Name rules are a heuristic.</p>
        ${D.warnings.map((w) => `<p class="rev">${esc(w)}</p>`).join('')}`;
    }
  }
  function hover(nodeId, edgeId) {
    const id = nodeId || edgeId;
    if (!id && S.sel) return apply();
    apply(nodeId ? { node: nodeId } : edgeId ? { edge: edgeId } : null);
  }
  function select(sel) {
    S.sel = sel && S.sel && JSON.stringify(sel) === JSON.stringify(S.sel) ? null : sel;
    apply();
    panel();
  }

  function apply(focus = S.sel) {
    const s = S.step, last = s === D.steps.length - 1;
    svg.classList.toggle('lens', S.lens);
    // Past a few, always-on rule labels hide the graph; they stay on hover and in the panel.
    svg.classList.toggle('few', D.edges.filter((e) => e.rule).length <= 8);
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
    for (const { g, e } of edgeEls.values()) {
      g.classList.toggle('future', e.firstStep > s);
      g.classList.toggle('now', S.moved && e.txs.some((d) => stepTx.has(d.i)));
      g.classList.remove('hot');
    }
    svg.classList.toggle('dim', !!focus);
    if (focus) {
      const hot = new Set();
      for (const { g, e } of edgeEls.values())
        if (focus.edge === e.id || e.from === focus.node || e.to === focus.node) {
          g.classList.add('hot');
          hot.add(e.from).add(e.to);
        }
      if (focus.node) hot.add(focus.node);
      for (const id of hot) nodeEls.get(id)?.classList.add('hot');
    }
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

  const go = (s) => {
    S.step = Math.max(0, Math.min(D.steps.length - 1, s));
    S.moved = true;
    svg.classList.add('anim');
    apply();
  };
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
  document.addEventListener('keydown', (e) => {
    if (e.target.tagName === 'INPUT' && e.target.type !== 'range' && e.target.type !== 'checkbox') return;
    if (e.key === 'ArrowRight') { go(S.step + 1); e.preventDefault(); }
    else if (e.key === 'ArrowLeft') { go(S.step - 1); e.preventDefault(); }
    else if (e.key === 'Home') go(0);
    else if (e.key === 'End') go(D.steps.length - 1);
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
  const legend = `<div class="legend" aria-hidden="true">
<span><svg width="28" height="10"><path d="M0,5 H28" stroke="var(--edge)" stroke-dasharray="1 3" stroke-linecap="round" stroke-width="1.5"/></svg> created by</span>
<span><svg width="28" height="10"><path d="M0,5 H28" stroke="var(--edge)" stroke-width="1.5"/></svg> set at deploy</span>
<span><svg width="28" height="10"><path d="M0,5 H28" stroke="var(--edge)" stroke-dasharray="6 3" stroke-width="1.5"/></svg> set by call</span>
<span><svg width="28" height="10"><path d="M0,5 H28" stroke="var(--accent)" stroke-width="2"/></svg> control rule matched</span>
<span>⚑ controlled by an outside address</span>${model.sprue ? '<span>✓ certified role; thick solid line: certificate-verified link</span>' : ''}
<span>dashed box: not created by this deployment</span></div>`;
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light dark"><title>${esc(title)}</title><style>${CSS}</style></head>
<body><header><h1>${esc(title)}</h1><p>${s.contracts} contracts, ${s.nodes - s.contracts} outside addresses, ${s.edges} links, ${s.steps} steps, from ${s.records} broadcast record files. Built offline from forge's records; links show what the records say, not what the chain holds now.</p></header>
<div class="bar" id="topbar"><button class="tab" id="tab-map" aria-selected="true">Map</button><button class="tab" id="tab-table" aria-selected="false">Table</button>
<span id="playbar" style="display:contents"><button id="first" aria-label="first step">⏮</button><button id="prev" aria-label="previous step">◀</button><span id="count" aria-live="polite"></span><button id="next" aria-label="next step">▶</button><button id="lastb" aria-label="last step">⏭</button>
<input id="scrub" type="range" min="0" step="1" aria-label="step"><label class="chk"><input type="checkbox" id="lens" checked> control lens</label></span></div>
<div id="mapview"><div id="stepinfo" aria-live="polite"></div>${legend}<main><div id="mapwrap"></div><aside id="panel" aria-live="polite"></aside></main></div>
<section id="tableview" class="hidden"><input id="filter" type="search" placeholder="Filter transactions" aria-label="Filter transactions">
<table><caption class="muted" style="text-align:left">One row per transaction, in order.</caption><thead><tr><th>Step</th><th>Script</th><th>Type</th><th>Target</th><th>Function</th><th>Arguments</th><th>Status</th><th>Hash</th></tr></thead><tbody id="tbody"></tbody></table></section>
<script type="application/json" id="data">${data}</script>
<script>(${client.toString()})();</script></body></html>
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
  process.stdout.write(render(model, title || `Deployment map: ${[...new Set(model.txs.map((x) => x.script))].join(', ')}`.slice(0, 120)));
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

// SPDX-License-Identifier: MIT
// What a call says: keccak256 for selectors and topics, ABI type trees, calldata decoding and forge's argument
// strings.
//
// A type tree is {k:'base',t} | {k:'arr',of,len} | {k:'tuple',comps}; any node may carry `name`. A value tree is
// {type, value} for a leaf and {type, children} otherwise.
//
// Guarantees: a decoder either returns the whole tree or throws; callers read a throw as "not decoded".
//   Reading past the calldata, an address word with non-zero high bytes and an array of over 10000 elements throw.
//   An array's head must fit in the calldata before anything is allocated for it; the 10000 limit is per array.
//   Decoded addresses are EIP-55 checksummed, as forge prints them.
// Relies on: `decTuple` takes calldata hex without the `0x` and the selector.

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
  for (let i = 0; i < 4; i++) {
    for (let b = 0; b < 8; b++) hex += ((s[i] >> BigInt(8 * b)) & 0xffn).toString(16).padStart(2, '0');
  }
  return hex;
}

export const selectorOf = (sig) => '0x' + keccak256(new TextEncoder().encode(sig)).slice(0, 8);
export const topicOf = (s) => '0x' + keccak256(new TextEncoder().encode(s));

export function checksum(a) {
  const h = a.slice(2).toLowerCase(), k = keccak256(new TextEncoder().encode(h));
  return '0x' + [...h].map((c, i) => (parseInt(k[i], 16) >= 8 ? c.toUpperCase() : c)).join('');
}

// `name(types)` or `function name(type a, ...) returns (...)` → {name, params}; null when it does not parse.
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

export const canonical = (t) =>
  t.k === 'base' ? t.t : t.k === 'arr' ? `${canonical(t.of)}[${t.len ?? ''}]` : `(${t.comps.map(canonical).join(',')})`;

export function fromAbiInput(inp) {
  let t;
  const m = /^tuple((?:\[\d*\])*)$/.exec(inp.type);
  if (m) {
    t = { k: 'tuple', comps: (inp.components || []).map(fromAbiInput) };
    for (const d of m[1].match(/\[\d*\]/g) || []) {
      t = { k: 'arr', of: t, len: d === '[]' ? null : Number(d.slice(1, -1)) };
    }
  } else t = parseParam(inp.type);
  if (inp.name) t.name = inp.name;
  return t;
}

// Copies names from `named` onto the same-shaped `typed`; a shape mismatch keeps `typed` as it is.
export function withNames(typed, named) {
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

export const ADDR = /^0x[0-9a-fA-F]{40}$/;
export const ADDR_IN = /(?<![0-9a-fA-Fx])0x[0-9a-fA-F]{40}(?![0-9a-fA-F])/g;

// forge's argument strings: arrays `[a, b]`, tuples `(a, b)`, strings unquoted. Throws on a shape mismatch,
// a fixed array of another length included.
export function parseArgString(t, s) {
  s = String(s).trim();
  if (t.k === 'base') return { type: t, value: s };

  const [open, close] = t.k === 'tuple' ? ['(', ')'] : ['[', ']'];
  if (!s.startsWith(open) || !s.endsWith(close)) throw new Error('shape');

  const inner = s.slice(1, -1);
  const parts = inner.trim() === '' ? [] : splitTop(inner, ', ');
  const kids = t.k === 'tuple' ? t.comps : parts.map(() => t.of);
  if (kids.length !== parts.length || (t.k === 'arr' && t.len !== null && t.len !== parts.length)) {
    throw new Error('shape');
  }
  return { type: t, children: parts.map((p, i) => parseArgString(kids[i], p)) };
}

export function decTuple(types, hex, start) {
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

// Leaves as {path, name, type, value}; `path` is the parameter name (or arg<i>) with indices. Type '?' is a
// positional leaf whose type is unknown.
export function leaves(trees) {
  const out = [];
  const walk = (n, path, name) => {
    if (n.children) {
      n.children.forEach((c, i) => {
        walk(c, n.type.k === 'arr' ? `${path}[${i}]` : `${path}.${c.type.name ?? i}`, c.type.name ?? name);
      });
    } else out.push({ path, name, type: n.type.k === 'base' ? n.type.t : '?', value: n.value });
  };
  trees.forEach((n, i) => walk(n, n.type.name ?? `arg${i}`, n.type.name ?? null));
  return out;
}

export function show(tree) {
  if (tree.children) {
    const inner = tree.children.map(show).join(', ');
    return tree.type.k === 'tuple' ? `(${inner})` : `[${inner}]`;
  }
  return String(tree.value);
}

export const lc = (a) => (a ? String(a).toLowerCase() : a);
export const ZERO = '0x' + '0'.repeat(40);

// Signatures for calls that the records and out/ leave undecoded.
export const COMMON = [
  'transferOwnership(address newOwner)', '_transferOwnership(address newOwner)', 'acceptOwnership()',
  'renounceOwnership()', 'grantRole(bytes32 role, address account)', 'revokeRole(bytes32 role, address account)',
  'renounceRole(bytes32 role, address account)', 'setOwner(address owner)', 'setAdmin(address admin)',
  'changeAdmin(address newAdmin)', 'upgradeTo(address newImplementation)',
  'upgradeToAndCall(address newImplementation, bytes data)', 'initialize()', 'approve(address spender, uint256 amount)',
  'transfer(address to, uint256 amount)', 'transferFrom(address from, address to, uint256 amount)',
  'mint(address to, uint256 amount)',
].map(parseSignature);
export const commonSig = (p) => `${p.name}(${p.params.map(canonical).join(',')})`;

// Keccak-f[1600] on BigInt lanes: slow, and fast enough for selectors and topics.
const M64 = (1n << 64n) - 1n;
const RC = [
  0x1n, 0x8082n, 0x800000000000808an, 0x8000000080008000n, 0x808bn, 0x80000001n, 0x8000000080008081n,
  0x8000000000008009n, 0x8an, 0x88n, 0x80008009n, 0x8000000an, 0x8000808bn, 0x800000000000008bn,
  0x8000000000008089n, 0x8000000000008003n, 0x8000000000008002n, 0x8000000000000080n, 0x800an,
  0x800000008000000an, 0x8000000080008081n, 0x8000000000008080n, 0x80000001n, 0x8000000080008008n,
];
const ROT = [
  [0, 36, 3, 41, 18], [1, 44, 10, 45, 2], [62, 6, 43, 15, 61], [28, 55, 25, 21, 56], [27, 20, 39, 8, 14],
];
const rotl = (x, n) => (n === 0 ? x : ((x << BigInt(n)) | (x >> BigInt(64 - n))) & M64);

function keccakF(s) {
  for (let r = 0; r < 24; r++) {
    const C = [0, 1, 2, 3, 4].map((x) => s[x] ^ s[x + 5] ^ s[x + 10] ^ s[x + 15] ^ s[x + 20]);
    for (let x = 0; x < 5; x++) {
      const D = C[(x + 4) % 5] ^ rotl(C[(x + 1) % 5], 1);
      for (let y = 0; y < 25; y += 5) s[y + x] ^= D;
    }

    const B = new Array(25);
    for (let x = 0; x < 5; x++) {
      for (let y = 0; y < 5; y++) B[y + 5 * ((2 * x + 3 * y) % 5)] = rotl(s[x + 5 * y], ROT[x][y]);
    }
    for (let x = 0; x < 5; x++) {
      for (let y = 0; y < 5; y++) {
        s[x + 5 * y] = B[x + 5 * y] ^ (~B[((x + 1) % 5) + 5 * y] & M64 & B[((x + 2) % 5) + 5 * y]);
      }
    }
    s[0] ^= RC[r];
  }
}

// Splits at `sep` outside any bracket; a trailing empty piece is kept only after a separator.
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

  const qualifiers = ['memory', 'calldata', 'storage', 'indexed', 'payable'];
  const words = s.trim().split(/\s+/).filter((w) => w && !qualifiers.includes(w));
  if (words.length) t.name = words[words.length - 1];
  return t;
}

function parseParams(list) {
  return list.trim() === '' ? [] : splitTop(list).map(parseParam);
}

function word(hex, pos) {
  const w = hex.slice(pos * 2, pos * 2 + 64);
  if (w.length !== 64) throw new Error('short calldata');
  return w;
}

const isDyn = (t) =>
  t.k === 'base' ? t.t === 'bytes' || t.t === 'string'
    : t.k === 'arr' ? t.len === null || isDyn(t.of)
      : t.comps.some(isDyn);
const headSize = (t) =>
  isDyn(t) ? 32
    : t.k === 'base' ? 32
      : t.k === 'arr' ? t.len * headSize(t.of)
        : t.comps.reduce((a, c) => a + headSize(c), 0);

// The encoded head must fit in the calldata before anything is allocated for it: a fixed array of a huge
// length would otherwise allocate before its first read failed.
function fits(hex, pos, bytes) {
  if (pos * 2 + bytes * 2 > hex.length) throw new Error('short calldata');
}

function decAt(t, hex, pos) {
  if (t.k === 'tuple') return { type: t, children: decTuple(t.comps, hex, pos) };

  if (t.k === 'arr') {
    if (t.len !== null) {
      fits(hex, pos, t.len * headSize(t.of));
      if (t.len > 10000) throw new Error('bad length');
      return { type: t, children: decTuple(Array(t.len).fill(t.of), hex, pos) };
    }
    const n = Number(BigInt('0x' + word(hex, pos)));
    if (n > 10000) throw new Error('bad length');
    fits(hex, pos + 32, n * headSize(t.of));
    return { type: t, children: decTuple(Array(n).fill(t.of), hex, pos + 32) };
  }

  const w = word(hex, pos), b = t.t;
  if (b === 'address') {
    if (!/^0{24}/.test(w)) throw new Error('dirty address');
    return { type: t, value: checksum('0x' + w.slice(24)) };
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

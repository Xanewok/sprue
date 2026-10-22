// node --test map/test/map.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { cpSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

import { build, keccak256, place, GEOM } from '../index.mjs';
import { sprueLayer } from '../sprue-layer.mjs';
import { PROFILES, compile, matchRule, replayControl } from '../control.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const sprue = join(here, '..', '..', 'bin', 'sprue.mjs');
const fixture = join(here, 'token-vault');

function exec(args, cwd) {
  return spawnSync(process.execPath, [sprue, 'map', ...args], { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
}
function run(args, cwd = fixture) {
  const r = exec(args, cwd);
  assert.equal(r.status, 0, r.stderr);
  const html = r.stdout;
  const data = JSON.parse(/<script type="application\/json" id="data">([\s\S]*?)<\/script>/.exec(html)[1]);
  return { html, data };
}
const named = (data, name) => data.nodes.find((n) => n.name === name);

test('maps the token-vault records: two contracts, their links, one step per transaction', () => {
  const { html, data } = run([]);
  assert.deepEqual(data.nodes.map((n) => [n.kind, n.name]).sort(), [['contract', 'Token'], ['contract', 'Vault'], ['sender', null]]);
  const token = named(data, 'Token'), vault = named(data, 'Vault');
  const edges = data.edges.map((e) => [e.kind, e.from, e.to, e.label]).sort();
  assert.deepEqual(edges, [['call', token.id, vault.id, 'transfer(to)'], ['deploy', vault.id, token.id, 'arg0']].sort());
  assert.equal(data.steps.length, 3, 'run-<ts>.json and <sig>-latest.json hold the same transactions once');
  assert.deepEqual(data.txs.map((x) => x.status), ['ok', 'ok', 'ok']);
  assert.ok(!/<script[^>]*\ssrc=|<link[^>]*\shref=|https?:\/\/(?!www\.w3\.org\/2000\/svg)/.test(html), 'the page loads nothing');
});

test('the sprue layer adds roles, plan step ids and the certificate-verified link', () => {
  const { data } = run(['local']);
  assert.deepEqual(data.steps.map((s) => s.id), ['token.deploy', 'vault.deploy', 'vault.fund']);
  assert.deepEqual(data.nodes.filter((n) => n.certified).map((n) => n.role).sort(), ['token', 'vault']);
  const verified = data.edges.filter((e) => e.verified).map((e) => [e.kind, e.label]);
  assert.deepEqual(verified, [['deploy', 'arg0']]);
});

test('a journal transaction hash names its step only on its own chain', () => {
  const dir = mkdtempSync(join(tmpdir(), 'deploy-map-'));
  try {
    const hash = '0x' + '7'.repeat(64);
    mkdirSync(join(dir, 'net'));
    writeFileSync(join(dir, 'net', 'vault.json'), JSON.stringify({ vaultChainId: 1, vault: '0x' + 'a'.repeat(40), vaultTx: hash }));
    const step = (i, chain) => ({ i, chain, hash, script: 'Deploy.s.sol', sig: 'deploy' });
    const ids = sprueLayer({ dir, network: 'net' }, [step(0, 1), step(1, 2)], new Map(), new Map(), []);
    assert.deepEqual([...ids], [[0, 'vault.deploy']]);
  } finally {
    rmSync(dir, { recursive: true });
  }
});

test('a reverted CREATE is a step that creates nothing', () => {
  const dir = mkdtempSync(join(tmpdir(), 'deploy-map-'));
  try {
    cpSync(join(fixture, 'broadcast'), join(dir, 'broadcast'), { recursive: true });
    const vaultDir = join(dir, 'broadcast', 'DeployVault.s.sol', '31337');
    const vaultTx = JSON.parse(readFileSync(join(vaultDir, 'deploy-latest.json'), 'utf8')).transactions[0].hash;
    for (const f of readdirSync(vaultDir)) {
      const j = JSON.parse(readFileSync(join(vaultDir, f), 'utf8'));
      for (const r of j.receipts) if (r.transactionHash === vaultTx) r.status = '0x0';
      writeFileSync(join(vaultDir, f), JSON.stringify(j));
    }
    const { data } = run(['--records', join(dir, 'broadcast')], dir);
    assert.equal(data.steps.length, 3);
    const x = data.txs.find((t) => t.hash === vaultTx);
    assert.equal(x.status, 'reverted');
    assert.deepEqual(x.created, []);
    assert.equal(named(data, 'Vault'), undefined);
    assert.ok(!data.edges.some((e) => e.kind === 'deploy'), 'a reverted CREATE binds nothing');
  } finally {
    rmSync(dir, { recursive: true });
  }
});

test('no link crosses a box, at desktop and phone width', () => {
  const { data } = run(['local']);
  for (const width of [1060, 390]) {
    const { g, box, routes } = place(data, GEOM, width);
    assert.equal(routes.length, 2);
    for (const r of routes)
      for (let i = 1; i < r.pts.length; i++) {
        const [[x1, y1], [x2, y2]] = [r.pts[i - 1], r.pts[i]];
        assert.ok(x1 === x2 || y1 === y2, 'links run in straight segments');
        for (const [id, b] of box) {
          const inside = Math.min(x1, x2) < b.x + g.w - 0.5 && Math.max(x1, x2) > b.x + 0.5 && Math.min(y1, y2) < b.y + g.h - 0.5 && Math.max(y1, y2) > b.y + 0.5;
          assert.ok(!inside, `${r.key} crosses ${id} at width ${width}`);
        }
      }
  }
});

// Twelve contracts in one script, two outside addresses, links between most of them.
function dense() {
  const nodes = [];
  for (let k = 0; k < 12; k++) nodes.push({ id: `1:c${k}`, chain: 1, kind: 'contract', laneKey: '1|Deploy.s.sol', ord: k + 1 });
  nodes.push({ id: '1:d', chain: 1, kind: 'sender', laneKey: '1|outside', ord: 0 }, { id: '1:o', chain: 1, kind: 'outside', laneKey: '1|outside', ord: 13 });
  const edges = [];
  for (let k = 0; k < 12; k++)
    for (const to of [(k * 5 + 3) % 12, (k * 7 + 1) % 12]) if (to !== k) edges.push({ from: `1:c${k}`, to: `1:c${to}` });
  for (let k = 0; k < 12; k += 3) edges.push({ from: `1:c${k}`, to: '1:d' }, { from: `1:c${k + 1}`, to: '1:o' });
  return { nodes, edges, lanes: ['1|outside', '1|Deploy.s.sol'] };
}

const segments = (routes) =>
  routes.flatMap((r) => r.pts.slice(1).map(([x2, y2], i) => {
    const [x1, y1] = r.pts[i];
    return { r, x1: Math.min(x1, x2), x2: Math.max(x1, x2), y1: Math.min(y1, y2), y2: Math.max(y1, y2) };
  }));

test('links that share no end never share a track, however many cross one gap', () => {
  for (const width of [1060, 390]) {
    const { g, box, routes, W } = place(dense(), GEOM, width);
    assert.ok(W <= width, `the map fits width ${width}`);
    const segs = segments(routes);
    for (const s of segs)
      for (const [id, b] of box)
        assert.ok(!(s.x1 < b.x + g.w - 0.5 && s.x2 > b.x + 0.5 && s.y1 < b.y + g.h - 0.5 && s.y2 > b.y + 0.5), `${s.r.key} crosses ${id}`);
    for (const a of segs)
      for (const b of segs) {
        if (a.r.from === b.r.from || a.r.to === b.r.to) continue;
        const vertical = a.x1 === a.x2 && b.x1 === b.x2 && a.x1 === b.x1 && Math.min(a.y2, b.y2) - Math.max(a.y1, b.y1) > 1;
        const horizontal = a.y1 === a.y2 && b.y1 === b.y2 && a.y1 === b.y1 && Math.min(a.x2, b.x2) - Math.max(a.x1, b.x1) > 1;
        assert.ok(!vertical && !horizontal, `${a.r.key} and ${b.r.key} share a track at width ${width}`);
      }
  }
});

test('short lanes of one chain share a row, each as wide as its boxes', () => {
  const lanes = ['1|outside', '1|A.s.sol', '1|B.s.sol', '1|C.s.sol'];
  const nodes = [['a0', 'A'], ['b0', 'B'], ['b1', 'B'], ['c0', 'C'], ['c1', 'C'], ['c2', 'C']].map(([id, s], k) => ({ id: `1:${id}`, chain: 1, kind: 'contract', laneKey: `1|${s}.s.sol`, ord: k }));
  const { box, lanes: placed } = place({ nodes, edges: [{ from: '1:b0', to: '1:a0' }], lanes }, GEOM, 1060);
  const [a, b, c] = placed;
  assert.equal(a.y0, b.y0, 'A and B fit in one row of four columns');
  assert.ok(c.y0 > b.y1, 'C does not fit beside them');
  assert.ok(a.x1 <= b.x0, 'lanes on one row do not overlap');
  assert.equal(new Set([...box.values()].map((p) => p.y)).size, 2);
});

test('no link crosses a lane title', () => {
  const lanes = ['1|outside', '1|First.s.sol', '1|Second.s.sol', '1|Third.s.sol'];
  const nodes = [];
  for (let k = 0; k < 15; k++) nodes.push({ id: `1:n${k}`, chain: 1, kind: 'contract', laneKey: lanes[1 + Math.floor(k / 5)], ord: k });
  const edges = [];
  for (let k = 0; k < 15; k++) edges.push({ from: `1:n${k}`, to: `1:n${(k * 4 + 7) % 15}` }, { from: `1:n${k}`, to: `1:n${(k + 5) % 15}` });
  for (const width of [1060, 390]) {
    const { lanes: placed, routes } = place({ nodes, edges: edges.filter((e) => e.from !== e.to), lanes }, GEOM, width);
    assert.equal(placed.length, 3);
    for (const { key, title: t } of placed) {
      assert.ok(t.w > 40, `${key} has room for its title`);
      for (const s of segments(routes))
        assert.ok(!(s.x1 < t.x + t.w && s.x2 > t.x && s.y1 < t.y + t.h && s.y2 > t.y), `${s.r.key} crosses the title of ${key} at width ${width}`);
    }
  }
});

// A synthetic record: one transaction per entry, each with the logs given.
const topic = (sig) => '0x' + keccak256(new TextEncoder().encode(sig));
const word = (a) => '0x' + a.replace(/^0x/, '').padStart(64, '0');
const A = '0x' + 'a'.repeat(40), P = '0x' + 'c'.repeat(40), R = '0x' + 'e'.repeat(40), X = '0x' + 'f'.repeat(40);
const D = '0x' + '1'.repeat(40), B = '0x' + '2'.repeat(40), Q = '0x' + '3'.repeat(40), M = '0x' + '4'.repeat(40), U = '0x' + '5'.repeat(40);
const ZERO = '0x' + '0'.repeat(40);
const owned = (at, from, to) => ({ address: at, topics: [topic('OwnershipTransferred(address,address)'), word(from), word(to)], data: '0x' });
const role = (ev, at, id, who) => ({ address: at, topics: [topic(`${ev}(bytes32,address,address)`), id, word(who), word(D)], data: '0x' });
const MINTER = topic('MINTER_ROLE'), CUSTOM = '0x' + '12345678'.repeat(8);
const TXS = [
  ['CREATE', 'Owned', A, [owned(A, ZERO, D)]],
  ['CALL', 'Owned', A, [owned(A, D, B)]],
  ['CALL', 'Owned', A, [owned(A, B, ZERO)]],
  ['CREATE', 'Roles', R, [role('RoleGranted', R, MINTER, M), role('RoleGranted', R, CUSTOM, U)]],
  ['CALL', 'Roles', R, [role('RoleRevoked', R, MINTER, M)]],
  ['CREATE', 'Owned2Step', P, [owned(P, ZERO, D)]],
  ['CALL', 'Owned2Step', P, [{ address: P, topics: [topic('OwnershipTransferStarted(address,address)'), word(D), word(Q)], data: '0x' }]],
  // ERC-1967's AdminChanged indexes nothing: both addresses are data words.
  ['CREATE', 'Proxy', X, [{ address: X, topics: [topic('AdminChanged(address,address)')], data: word(ZERO) + word(B).slice(2) }]],
  // Upgraded indexes its argument; the second upgrade replaces the first.
  ['CALL', 'Proxy', X, [{ address: X, topics: [topic('Upgraded(address)'), word(U)], data: '0x' }]],
  ['CALL', 'Proxy', X, [{ address: X, topics: [topic('Upgraded(address)'), word(M)], data: '0x' }]],
];
function controlModel() {
  const dir = mkdtempSync(join(tmpdir(), 'deploy-map-'));
  const rec = join(dir, 'broadcast', 'Deploy.s.sol', '1');
  const hash = (i) => '0x' + String(i + 1).padStart(64, '0');
  const j = {
    chain: 1, timestamp: 1,
    transactions: TXS.map(([type, name, at], i) => ({ hash: hash(i), transactionType: type, contractName: name, contractAddress: at,
      function: type === 'CALL' ? 'touch()' : null, arguments: null, transaction: { from: D, to: type === 'CALL' ? at : null, nonce: '0x' + i.toString(16), input: type === 'CALL' ? '0xa55526db' : '0x00' } })),
    receipts: TXS.map(([, , , logs], i) => ({ transactionHash: hash(i), status: '0x1', blockNumber: '0x' + (i + 1).toString(16), logs: logs.map((l, k) => ({ ...l, logIndex: '0x' + k.toString(16) })) })),
  };
  try {
    mkdirSync(rec, { recursive: true });
    writeFileSync(join(rec, 'run-latest.json'), JSON.stringify(j));
    return build({ paths: [join(dir, 'broadcast')] });
  } finally {
    rmSync(dir, { recursive: true });
  }
}
const at = (m, from, label) => m.edges.filter((e) => e.kind === 'event' && e.from === `1:${from}` && e.label === label);

test('ownership events replay in order: a later owner replaces the last, a transfer to zero renounces', () => {
  const m = controlModel();
  assert.deepEqual(at(m, A, 'owner').map((e) => [e.to, e.spans]), [[`1:${D}`, [[0, 1]]], [`1:${B}`, [[1, 2]]]]);
  assert.deepEqual(m.renounced.map((r) => [r.from, r.label, r.spans]), [[`1:${A}`, 'owner', [[2, null]]]]);
});

test('a revoked role ends its span', () => {
  assert.deepEqual(at(controlModel(), R, 'MINTER_ROLE').map((e) => [e.to, e.spans]), [[`1:${M}`, [[3, 4]]]]);
});

test('an unknown role id shows short', () => {
  assert.deepEqual(at(controlModel(), R, 'role 0x12345678…').map((e) => [e.to, e.spans]), [[`1:${U}`, [[3, null]]]]);
});

test('a pending owner is shown but not counted as control; the proxy admin is read from data words', () => {
  const m = controlModel();
  const [pending] = at(m, P, 'pending owner');
  assert.equal(pending.to, `1:${Q}`);
  assert.equal(pending.cls, 'pending');
  assert.deepEqual(at(m, P, 'owner').map((e) => [e.to, e.spans]), [[`1:${D}`, [[5, null]]]]);
  assert.deepEqual(at(m, X, 'proxy admin').map((e) => [e.to, e.spans]), [[`1:${B}`, [[7, null]]]]);
  assert.equal(m.stats.control, 6, 'three owners, two roles and the proxy admin; not the pending owner');
});

test('a bespoke profile in the same shape drives the replay: Celo\'s OwnerSet(address)', () => {
  const celo = { name: 'Celo Ownable', events: [{ sig: 'OwnerSet(address)', effect: 'owner', holder: 0 }] };
  const logs = [[{ address: A, logIndex: '0x0', topics: [topic('OwnerSet(address)'), word(D)], data: '0x' }]];
  const replay = (table) => {
    const edges = new Map();
    const nodeOf = (chain, a) => ({ id: `${chain}:${a}` });
    replayControl([{ i: 0, chain: 1 }], logs, nodeOf, (chain, a) => `${chain}:${a}`, edges, { events: 0 }, table);
    return [...edges.values()].map((e) => [e.from, e.to, e.label, e.event]);
  };
  assert.deepEqual(replay(compile(PROFILES)), [], 'unknown to the built-ins');
  assert.deepEqual(replay(compile([...PROFILES, celo])), [[`1:${A}`, `1:${D}`, 'owner', 'OwnerSet']]);
});

test('an ERC-1967 upgrade is an implementation link, replaced by the next, and not control', () => {
  const m = controlModel();
  const impl = m.edges.filter((e) => e.kind === 'impl' && e.from === `1:${X}`);
  assert.deepEqual(impl.map((e) => [e.to, e.label, e.cls, e.spans]), [[`1:${U}`, 'implementation', 'impl', [[8, 9]]], [`1:${M}`, 'implementation', 'impl', [[9, null]]]]);
  assert.equal(m.stats.control, 6, 'the implementation links add no control');
});

test('a bare Foundry project maps from foundry.toml and broadcast/ alone', () => {
  const dir = mkdtempSync(join(tmpdir(), 'deploy-map-'));
  try {
    cpSync(join(fixture, 'broadcast'), join(dir, 'broadcast'), { recursive: true });
    writeFileSync(join(dir, 'foundry.toml'), '[profile.default]\n');
    const { data } = run([], dir);
    assert.deepEqual(data.nodes.map((n) => n.name).filter(Boolean).sort(), ['Token', 'Vault']);
    assert.ok(!data.sprue);
    const r = exec(['local'], dir);
    assert.equal(r.status, 2);
    assert.match(r.stderr, /no sprue\.json: drop the network/);
  } finally {
    rmSync(dir, { recursive: true });
  }
});

test('the out and broadcast paths come from forge, not from fixed names', () => {
  const dir = mkdtempSync(join(tmpdir(), 'deploy-map-'));
  try {
    cpSync(join(fixture, 'broadcast'), join(dir, 'chain-records'), { recursive: true });
    writeFileSync(join(dir, 'foundry.toml'), '[profile.default]\nout = "build-out"\nbroadcast = "chain-records"\n');
    mkdirSync(join(dir, 'build-out', 'Vault.sol'), { recursive: true });
    writeFileSync(join(dir, 'build-out', 'Vault.sol', 'Vault.json'), JSON.stringify({ abi: [{ type: 'constructor', inputs: [{ name: 'asset', type: 'address', internalType: 'address' }] }] }));
    const { data } = run([], dir);
    assert.deepEqual(data.nodes.map((n) => n.name).filter(Boolean).sort(), ['Token', 'Vault']);
    assert.ok(data.edges.some((e) => e.kind === 'deploy' && e.label === 'asset'), 'names come from the configured out');
  } finally {
    rmSync(dir, { recursive: true });
  }
});

test('a project without a working forge is refused with the fix; --records alone needs no forge', () => {
  const bin = mkdtempSync(join(tmpdir(), 'deploy-map-'));
  try {
    writeFileSync(join(bin, 'forge'), '#!/bin/sh\nexit 1\n', { mode: 0o755 });
    const env = { ...process.env, PATH: `${bin}:${process.env.PATH}` };
    const go = (args, cwd) => spawnSync(process.execPath, [sprue, 'map', ...args], { cwd, env, encoding: 'utf8' });
    const r = go([], fixture);
    assert.equal(r.status, 2, r.stderr);
    assert.equal(r.stdout, '');
    assert.match(r.stderr, /forge config --json failed.*install Foundry.*--records/);
    const bare = mkdtempSync(join(tmpdir(), 'deploy-map-'));
    try {
      const ok = go(['--records', join(fixture, 'broadcast')], bare);
      assert.equal(ok.status, 0, ok.stderr);
    } finally {
      rmSync(bare, { recursive: true });
    }
  } finally {
    rmSync(bin, { recursive: true });
  }
});

test('map refuses what does not apply and names the fix', () => {
  const refused = (args, cwd, re) => {
    const r = exec(args, cwd);
    assert.equal(r.status, 2, r.stderr);
    assert.equal(r.stdout, '');
    assert.match(r.stderr, re);
  };
  refused(['--wait'], fixture, /refusing --wait: map takes only --records, --out and --title/);
  refused(['nowhere'], fixture, /unknown network 'nowhere': no .*network\.json/);
  refused(['local', 'other'], fixture, /takes one network/);
  refused(['--out'], fixture, /--out needs a value/);
  refused(['--out', '-'], fixture, /refusing --out -: .*sprue map > map\.html/);
  const empty = mkdtempSync(join(tmpdir(), 'deploy-map-'));
  try {
    refused([], empty, /no foundry\.toml or sprue\.json .*--records/);
  } finally {
    rmSync(empty, { recursive: true });
  }
});

test('a terminal on stdout is refused with the fix; --out replaces the file it names', { skip: spawnSync('script', ['--version']).error && 'no script(1)' }, () => {
  const dir = mkdtempSync(join(tmpdir(), 'deploy-map-'));
  try {
    const tty = spawnSync('script', ['-qec', `${process.execPath} ${sprue} map`, '/dev/null'], { cwd: fixture, encoding: 'utf8' });
    assert.equal(tty.status, 2, tty.stdout);
    assert.match(tty.stdout, /--out map\.html.*> map\.html/s);
    assert.ok(!tty.stdout.includes('<!doctype'));
    writeFileSync(join(dir, 'm.html'), 'old');
    const r = spawnSync('script', ['-qec', `${process.execPath} ${sprue} map --out ${join(dir, 'm.html')}`, '/dev/null'], { cwd: fixture, encoding: 'utf8' });
    assert.equal(r.status, 0, r.stdout);
    assert.match(readFileSync(join(dir, 'm.html'), 'utf8'), /^<!doctype html>/);
  } finally {
    rmSync(dir, { recursive: true });
  }
});

test('--out writes the page to a file and leaves stdout empty; no transaction exits 1', () => {
  const dir = mkdtempSync(join(tmpdir(), 'deploy-map-'));
  try {
    const r = exec(['--out', join(dir, 'm.html')], fixture);
    assert.equal(r.status, 0, r.stderr);
    assert.equal(r.stdout, '');
    assert.match(readFileSync(join(dir, 'm.html'), 'utf8'), /^<!doctype html>/);
    writeFileSync(join(dir, 'foundry.toml'), '');
    assert.equal(exec([], dir).status, 2, 'no broadcast/ is a refusal');
    mkdirSync(join(dir, 'broadcast'));
    const e = exec([], dir);
    assert.equal(e.status, 1);
    assert.match(e.stderr, /no broadcast records with transactions/);
  } finally {
    rmSync(dir, { recursive: true });
  }
});

// Hand-written records: {chain: [{ts, txs: [{hash, to, input?, function?, arguments?, block, index, logs?}]}]}.
function modelOf(chains) {
  const dir = mkdtempSync(join(tmpdir(), 'deploy-map-'));
  try {
    let n = 0;
    for (const [chain, files] of Object.entries(chains))
      for (const f of files) {
        const d = join(dir, 'broadcast', 'Deploy.s.sol', chain);
        mkdirSync(d, { recursive: true });
        writeFileSync(join(d, `run-${++n}.json`), JSON.stringify({
          chain: Number(chain), timestamp: f.ts,
          transactions: f.txs.map((t, i) => ({ hash: t.hash, transactionType: 'CALL', contractName: 'C', contractAddress: t.to, function: t.function ?? 'touch()', arguments: t.arguments ?? null,
            transaction: { from: D, to: t.to, nonce: '0x' + (n * 10 + i).toString(16), input: t.input ?? '0xa55526db' } })),
          receipts: f.txs.map((t) => ({ transactionHash: t.hash, status: '0x1', blockNumber: '0x' + t.block.toString(16), transactionIndex: '0x' + (t.index ?? 0).toString(16),
            logs: (t.logs || []).map((l, k) => ({ ...l, logIndex: '0x' + k.toString(16) })) })),
        }));
      }
    return build({ paths: [join(dir, 'broadcast')] });
  } finally {
    rmSync(dir, { recursive: true });
  }
}
const H = (i) => '0x' + String(i).padStart(64, '0');
const replay = (logs, table) => {
  const edges = new Map(), stats = { events: 0, eventsSkipped: 0 };
  const renounced = replayControl(logs.map((_, i) => ({ i, chain: 1 })), logs.map((l) => [l]), (chain, a) => ({ id: `${chain}:${a}` }), (chain, a) => `${chain}:${a}`, edges, stats, table);
  return { edges: [...edges.values()], renounced, stats };
};

test('revokeRole is not a control link; grantRole still is', () => {
  assert.equal(matchRule('revokeRole', { name: 'account', path: 'account' }), null);
  assert.equal(matchRule('revokeRoles', { name: 'account', path: 'account' }), null);
  assert.equal(matchRule('revokeRole', { name: 'minter', path: 'minter' }), null);
  assert.equal(matchRule('renounceRole', { name: 'owner', path: 'owner' }), null);
  assert.equal(matchRule('grantRole', { name: 'account', path: 'account' }).cls, 'authority');
});

test('only EXECUTOR_ROLE granted to the zero address means anyone; no role is renounced', () => {
  const m = modelOf({ 1: [{ ts: 1, txs: [{ hash: H(1), to: R, block: 1, logs: [role('RoleGranted', R, MINTER, ZERO), role('RoleGranted', R, topic('EXECUTOR_ROLE'), ZERO)] }] }] });
  assert.deepEqual(m.renounced, []);
  const [e] = at(m, R, 'MINTER_ROLE'), [x] = at(m, R, 'EXECUTOR_ROLE');
  assert.equal(e.to, `1:${ZERO}`);
  assert.equal(x.to, e.to);
  assert.equal(m.nodes.find((n) => n.id === e.to).name, 'anyone (zero address)');
  const only = modelOf({ 1: [{ ts: 1, txs: [{ hash: H(1), to: R, block: 1, logs: [role('RoleGranted', R, MINTER, ZERO)] }] }] });
  assert.notEqual(only.nodes.find((n) => n.id === `1:${ZERO}`).name, 'anyone (zero address)');
});

test('roles whose ids share a prefix keep their own spans', () => {
  const r1 = '0x12345678' + '1'.repeat(56), r2 = '0x12345678' + '2'.repeat(56);
  const { edges } = replay([role('RoleGranted', R, r1, U), role('RoleGranted', R, r2, U), role('RoleRevoked', R, r1, U)]);
  assert.deepEqual(edges.map((e) => e.spansTx), [[[0, 2]], [[1, null]]]);
});

test('the same signed transaction on two chains is two transactions', () => {
  const tx = { hash: H(7), to: A, block: 1 };
  const m = modelOf({ 1: [{ ts: 1, txs: [tx] }], 2: [{ ts: 1, txs: [tx] }] });
  assert.equal(m.stats.txs, 2);
});

test('mined transactions replay in block order, not record-file order', () => {
  const later = { hash: H(1), to: A, block: 9, logs: [owned(A, D, B)] };
  const earlier = { hash: H(2), to: A, block: 3, logs: [owned(A, ZERO, D)] };
  const m = modelOf({ 1: [{ ts: 1, txs: [later] }, { ts: 2, txs: [earlier] }] });
  assert.deepEqual(at(m, A, 'owner').map((e) => [e.to, e.spans]), [[`1:${D}`, [[0, 1]]], [`1:${B}`, [[1, null]]]]);
});

test('a log whose indexed layout is not the declared one is skipped and counted', () => {
  const partly = { address: A, topics: [topic('OwnershipTransferred(address,address)'), word(B)], data: word(D) };
  const { edges, stats } = replay([partly, owned(A, ZERO, D)]);
  assert.equal(edges.length, 1);
  assert.equal(stats.eventsSkipped, 1);
  assert.equal(stats.events, 1);
});

test('calldata decides the arguments; the record strings are read only without it', () => {
  const input = '0x' + keccak256(new TextEncoder().encode('setAdmin(address)')).slice(0, 8) + word(B).slice(2);
  const m = modelOf({ 1: [{ ts: 1, txs: [{ hash: H(1), to: A, block: 1, function: 'setAdmin(address)', arguments: [Q], input }] }] });
  assert.deepEqual(m.edges.filter((e) => e.kind === 'call').map((e) => e.to), [`1:${B}`]);
  assert.equal(m.txs[0].decode, 'abi');
});

test('links from record strings after calldata fails to decode are not decoded', () => {
  const input = '0x' + keccak256(new TextEncoder().encode('setAdmin(address)')).slice(0, 8);
  const m = modelOf({ 1: [{ ts: 1, txs: [{ hash: H(1), to: A, block: 1, function: 'setAdmin(address)', arguments: [Q], input }] }] });
  assert.deepEqual(m.edges.filter((e) => e.kind === 'call').map((e) => [e.to, e.decoded]), [[`1:${Q}`, false]]);
});

test('a fixed array larger than the calldata is undecoded before it is allocated', () => {
  const run = (src) => spawnSync(process.execPath, ['--max-old-space-size=48', '--input-type=module', '-e', src], { encoding: 'utf8' });
  const abi = join(here, '..', 'abi.mjs');
  const r = run(`import { decTuple, parseSignature } from ${JSON.stringify(abi)};
    try { decTuple(parseSignature('f(address[100000000])').params, '00'.repeat(64), 0); console.log('decoded'); } catch (e) { console.log(e.message); }`);
  assert.equal(r.stdout.trim(), 'short calldata', r.stderr.slice(0, 200));
  const z = run(`import { decTuple, parseSignature } from ${JSON.stringify(abi)};
    try { decTuple(parseSignature('f(address[0][100000000])').params, '00'.repeat(64), 0); console.log('decoded'); } catch (e) { console.log(e.message); }`);
  assert.equal(z.stdout.trim(), 'bad length', z.stderr.slice(0, 200));
});

test('decoded addresses keep their EIP-55 checksum', async () => {
  const { decTuple, parseSignature } = await import('../abi.mjs');
  const [d] = decTuple(parseSignature('f(address)').params, '000000000000000000000000fb6916095ca1df60bb79ce92ce3ea74c37c5d359', 0);
  assert.equal(d.value, '0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359');
});

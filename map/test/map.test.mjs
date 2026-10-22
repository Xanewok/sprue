// node --test map/test/map.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { cpSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

import { build, keccak256, place, GEOM } from '../index.mjs';
import { PROFILES, compile, replayControl } from '../control.mjs';

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
    replayControl([{ i: 0, chain: 1 }], logs, nodeOf, (chain, a) => `${chain}:${a}`, edges, { events: 0, eventsUnplaced: 0 }, table);
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

// node --test tools/deploy-map/test/map.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { cpSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

import { place, GEOM } from '../map.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const map = join(here, '..', 'map.mjs');
const fixture = join(here, 'token-vault');

function run(...args) {
  const html = execFileSync(process.execPath, [map, ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  const data = JSON.parse(/<script type="application\/json" id="data">([\s\S]*?)<\/script>/.exec(html)[1]);
  return { html, data };
}
const named = (data, name) => data.nodes.find((n) => n.name === name);

test('maps the token-vault records: two contracts, their links, one step per transaction', () => {
  const { html, data } = run(join(fixture, 'broadcast'));
  assert.deepEqual(data.nodes.map((n) => [n.kind, n.name]).sort(), [['contract', 'Token'], ['contract', 'Vault'], ['sender', null]]);
  const token = named(data, 'Token'), vault = named(data, 'Vault');
  const edges = data.edges.map((e) => [e.kind, e.from, e.to, e.label]).sort();
  assert.deepEqual(edges, [['call', token.id, vault.id, 'transfer(to)'], ['deploy', vault.id, token.id, 'arg0']].sort());
  assert.equal(data.steps.length, 3, 'run-<ts>.json and <sig>-latest.json hold the same transactions once');
  assert.deepEqual(data.txs.map((x) => x.status), ['ok', 'ok', 'ok']);
  assert.ok(!/<script[^>]*\ssrc=|<link[^>]*\shref=|https?:\/\/(?!www\.w3\.org\/2000\/svg)/.test(html), 'the page loads nothing');
});

test('the sprue layer adds roles, plan step ids and the certificate-verified link', () => {
  const { data } = run('--sprue', fixture, 'local');
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
    const { data } = run(join(dir, 'broadcast'));
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
  const { data } = run('--sprue', fixture, 'local');
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

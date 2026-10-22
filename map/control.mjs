// SPDX-License-Identifier: MIT
import { lc, topicOf, ZERO } from './abi.mjs';

// First match wins. `authority` rules mark a contract as controlled by the address; `setter` rules only flag the edge.
export const RULES = [
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

export function matchRule(fnName, leaf) {
  for (const r of RULES) {
    if (r.fn && fnName && r.fn.test(fnName)) return r;
    if (r.param && ((leaf.name && r.param.test(leaf.name)) || (leaf.path && r.param.test(leaf.path.split(/[.[]/)[0])))) return r;
  }
  return null;
}

// A standard is data: the events it emits, what each does, and which parameter (by position in the event's
// declared order, indexed or not) holds the holder and the role. effect: owner | pendingOwner | proxyAdmin
// (one holder per slot), roleGranted | roleRevoked (any number of holders per role).
export const PROFILES = [
  { name: 'Ownable', events: [{ sig: 'OwnershipTransferred(address,address)', effect: 'owner', holder: 1 }] },
  { name: 'Ownable2Step', events: [{ sig: 'OwnershipTransferStarted(address,address)', effect: 'pendingOwner', holder: 1 }] },
  {
    name: 'AccessControl',
    events: [
      { sig: 'RoleGranted(bytes32,address,address)', effect: 'roleGranted', role: 0, holder: 1 },
      { sig: 'RoleRevoked(bytes32,address,address)', effect: 'roleRevoked', role: 0, holder: 1 },
    ],
    // OpenZeppelin AccessControl and TimelockController names only; a project's own role shows by its short id.
    roles: ['DEFAULT_ADMIN_ROLE', 'ADMIN_ROLE', 'MINTER_ROLE', 'BURNER_ROLE', 'PAUSER_ROLE', 'UPGRADER_ROLE', 'OPERATOR_ROLE',
      'GOVERNOR_ROLE', 'MANAGER_ROLE', 'SNAPSHOT_ROLE', 'URI_SETTER_ROLE', 'TIMELOCK_ADMIN_ROLE', 'PROPOSER_ROLE', 'EXECUTOR_ROLE',
      'CANCELLER_ROLE'],
  },
  { name: 'ERC-1967', events: [{ sig: 'AdminChanged(address,address)', effect: 'proxyAdmin', holder: 1 }] },
];
const SLOT = { owner: 'owner', pendingOwner: 'pending owner', proxyAdmin: 'proxy admin' };

export function compile(profiles) {
  const events = new Map(), roles = new Map();
  for (const p of profiles) {
    for (const e of p.events) {
      const params = e.sig.slice(e.sig.indexOf('(') + 1, -1).split(',').filter(Boolean);
      events.set(topicOf(e.sig), { ...e, name: e.sig.split('(')[0], arity: params.length, profile: p.name });
    }
    // OpenZeppelin defines DEFAULT_ADMIN_ROLE as zero, not as a hash of its name.
    for (const n of p.roles || []) roles.set(n === 'DEFAULT_ADMIN_ROLE' ? '0x' + '0'.repeat(64) : topicOf(n), n);
  }
  return { events, roles };
}
const BUILTIN = compile(PROFILES);

// Replays control events in transaction and log order. A slot (owner, pending owner, proxy admin) has one holder,
// so a new holder ends the last one's span; a role has any number. Spans are [first, end) transaction indices.
export function replayControl(out, logsOf, nodeOf, ref, edges, stats, table = BUILTIN) {
  const roleName = (id) => table.roles.get(id) || `role ${id.slice(0, 10)}…`;
  const slots = new Map(), renounced = [];
  const isOpen = (r) => r.spansTx.length && r.spansTx[r.spansTx.length - 1][1] === null;
  const begin = (r, x, detail) => {
    r.spansTx.push([x.i, null]);
    r.txs.push({ i: x.i, detail });
  };
  const end = (r, x, detail) => {
    r.spansTx[r.spansTx.length - 1][1] = x.i;
    r.txs.push({ i: x.i, detail, gone: true });
  };
  for (const x of out) {
    const logs = [...(logsOf[x.i] || [])].sort((a, b) => Number(a.logIndex) - Number(b.logIndex));
    logs.forEach((log, k) => {
      const ev = table.events.get(lc(log.topics?.[0]));
      if (!ev) return;
      // Topics after topic0, then data words: the declared order whether a library indexes all, none or the first.
      const words = [...log.topics.slice(1), ...(String(log.data || '0x').slice(2).match(/.{64}/g) || [])].map((w) => lc(w).replace(/^0x/, ''));
      if (words.length !== ev.arity || !/^0{24}[0-9a-f]{40}$/.test(words[ev.holder])) return;
      const from = nodeOf(x.chain, log.address);
      if (!from) { stats.eventsUnplaced++; return; }
      stats.events++;
      const who = '0x' + words[ev.holder].slice(24);
      const isRole = ev.effect === 'roleGranted' || ev.effect === 'roleRevoked';
      const revoke = ev.effect === 'roleRevoked';
      const pending = ev.effect === 'pendingOwner';
      const label = isRole ? roleName('0x' + words[ev.role]) : SLOT[ev.effect];
      const detail = `${ev.name}${isRole ? ' ' + label : ''}: ${revoke ? 'revoked from' : isRole ? 'to' : 'now'} ${who} (log ${log.logIndex !== undefined ? Number(log.logIndex) : k})`;
      const key = `${from.id}|${label}${isRole ? '|' + who : ''}`;
      const cur = slots.get(key);
      if (revoke) {
        if (cur && isOpen(cur)) end(cur, x, detail);
        return;
      }
      if (ev.effect === 'owner') {
        const p = slots.get(`${from.id}|pending owner`);
        if (p && isOpen(p)) end(p, x, detail);
      }
      if (cur && isOpen(cur)) {
        if (cur.holder === who) return void (cur.txs.some((d) => d.i === x.i) || cur.txs.push({ i: x.i, detail }));
        end(cur, x, detail);
      }
      if (who === ZERO) {
        if (pending) return;
        const r = { from: from.id, label, event: ev.name, holder: who, spansTx: [], txs: [] };
        renounced.push(r);
        begin(r, x, detail);
        slots.set(key, r);
        return;
      }
      const to = ref(x.chain, who, x.i);
      const id = `event|${from.id}|${to}|${label}`;
      let r = edges.get(id);
      if (!r) {
        // A contract that holds its own slot gets no link, but its span still ends the last holder's.
        r = { id, from: from.id, to, kind: 'event', label, rule: null, cls: pending ? 'pending' : 'authority', event: ev.name, decoded: true, txs: [], verified: false, spansTx: [], holder: who };
        if (to !== from.id) edges.set(id, r);
      }
      begin(r, x, detail);
      slots.set(key, r);
    });
  }
  // A name-rule link that an event in the same transaction confirms is one link with two sources.
  const evs = [...edges.values()].filter((e) => e.kind === 'event');
  for (const n of [...edges.values()]) {
    if (n.kind === 'event' || n.kind === 'created' || n.cls !== 'authority') continue;
    const e = evs.find((v) => v.from === n.from && v.to === n.to && n.txs.some((d) => v.txs.some((t) => t.i === d.i && !t.gone)));
    if (!e) continue;
    (e.names ||= []).push({ kind: n.kind, label: n.label, rule: n.rule });
    for (const d of n.txs) if (!e.txs.some((t) => t.i === d.i)) e.txs.push(d);
    e.txs.sort((a, b) => a.i - b.i);
    edges.delete(n.id);
  }
  return renounced;
}

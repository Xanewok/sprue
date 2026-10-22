// SPDX-License-Identifier: MIT
// The model of a deployment: what forge's records created, how the contracts link, and who controls what at each
// step. `build` reads records, `render` (page.mjs) draws the result.
//
// Maintains: a node is one address on one chain, with id `<chain>:<lowercase address>`, so the same address on two
// chains is two nodes. A transaction is a step, unless a sprue plan step groups consecutive ones.
// Guarantees: an address held by an argument becomes a node, an outside one when the deployment did not create
// it. `decoded` is false on a link that was not read from a typed value: the record's argument strings used
// after calldata failed to decode, or a 32-byte word that holds a known address (a selector with no known
// signature, undecodable calldata, initcode). Calldata decides the arguments; the record's argument strings
// are read only when there is none. A reverted transaction creates and binds nothing, but stays a step.
// Relies on `mergeTransactions` for the replay order, and on `replayControl` for the spans of control events.

import {
  ADDR, ADDR_IN, COMMON, canonical, commonSig, decTuple, leaves, lc, parseArgString, parseSignature, show, withNames,
} from './abi.mjs';
import { matchRule, replayControl } from './control.mjs';
import { Abis, knownSignatures, mergeTransactions, readRecords, statusOf } from './forge.mjs';
import { layout } from './layout.mjs';
import { sprueLayer } from './sprue-layer.mjs';

export function build({ paths, outDir, sprue }) {
  const records = readRecords(paths);
  const abis = new Abis(outDir);
  const warnings = [];
  const knownSigs = knownSignatures(records);
  const kept = mergeTransactions(records);

  const nodes = new Map();
  const nodeOf = (chain, addr) => nodes.get(`${chain}:${lc(addr)}`);
  const ensure = (chain, addr, init) => {
    const id = `${chain}:${lc(addr)}`;
    let n = nodes.get(id);
    if (!n) {
      n = {
        id, chain, addr: lc(addr), kind: 'outside', name: null, created: null, lane: null, refs: 0, firstRef: Infinity,
      };
      nodes.set(id, n);
    }
    Object.assign(n, init || {});
    return n;
  };
  // Records that transaction `i` mentions the address; the first mention places an outside address in the layout.
  const ref = (chain, addr, i) => {
    const n = ensure(chain, addr);
    n.refs++;
    n.firstRef = Math.min(n.firstRef, i);
    return n.id;
  };

  // Pass 1: transactions and the contracts they create.
  const out = [], logsOf = [];
  kept.forEach((e, i) => {
    const { t, rec, receipt } = e;
    const tx = t.transaction || {};
    const status = statusOf(receipt);
    const chain = rec.chain;
    const type = t.transactionType;
    const input = tx.input ?? tx.data ?? null;
    logsOf[i] = status === 'ok' ? receipt.logs || [] : [];

    const x = {
      i, chain, script: rec.script, sig: e.sig, type, hash: t.hash || null, from: lc(tx.from),
      to: lc(type === 'CALL' ? tx.to : t.contractAddress),
      contractName: /\(/.test(t.contractName || '') ? null : t.contractName || null,
      fn: t.function || (/^\w+\(.*\)$/.test(t.contractName || '') ? t.contractName : null),
      functionAbi: t.functionAbi || null, arguments: t.arguments ?? null, input,
      value: tx.value && BigInt(tx.value) !== 0n ? BigInt(tx.value).toString() : null,
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
      const via = prev && prev.transactionType === 'CREATE2' && !prev.contractName && c.transactionType === 'CREATE'
        ? lc(prev.address) : null;
      const n = ensure(chain, c.address, { kind: 'contract', lane, created: i });
      n.name = n.name || c.contractName || null;
      n.createdBy = { factory, via };
      x.created.push(n.id);
    });
  });

  // Names forge knew from later calls (a factory's unnamed child).
  for (const x of out) {
    if (x.type !== 'CALL' || !x.contractName) continue;
    const n = nodeOf(x.chain, x.to);
    if (n && !n.name) n.name = x.contractName;
  }

  // Pass 2: decode each transaction's arguments and link the addresses they hold to nodes by value.
  const edges = new Map();
  const addEdge = (from, to, kind, label, rule, x, decoded, detail) => {
    if (!from || !to || from === to) return;
    const id = `${kind}|${from}|${to}|${label}`;
    let ed = edges.get(id);
    if (!ed) {
      ed = {
        id, from, to, kind, label, rule: rule ? rule.id : null, cls: rule ? rule.cls : null, decoded,
        txs: [], verified: false,
      };
      edges.set(id, ed);
    }
    ed.decoded = ed.decoded && decoded;
    if (!ed.txs.some((d) => d.i === x.i)) ed.txs.push({ i: x.i, detail });
  };
  const stats = { txs: out.length, events: 0, eventsSkipped: 0 };

  for (const x of out) {
    const chain = x.chain;
    const isCreate = x.type === 'CREATE' || x.type === 'CREATE2';
    const { fnName, trees, mode, fallback } = decode(x, isCreate, abis, knownSigs, nodeOf);

    x.decode = mode;
    const ls = trees ? leaves(trees) : [];
    x.args = trees
      ? trees.map((t, k) => ({
        name: t.type.name ?? `arg${k}`,
        type: t.type.k === 'base' ? t.type.t : canonical(t.type),
        value: show(t),
      }))
      : [];
    if (x.status === 'reverted') continue;

    const source = `${chain}:${x.to}`;
    const touch = (addr) => ref(chain, addr, x.i);
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
    const initcodes = isCreate
      ? (x.arguments ? [] : [x.input])
      : x.created.length ? ls.filter((l) => l.type === 'bytes').map((l) => l.value) : [];
    for (const code of initcodes) {
      const hex = String(code || '').replace(/^0x/, '').toLowerCase();
      if (hex.length < 128) continue;
      const child = isCreate ? source : x.created[0];
      for (let w = 1; w <= Math.min(64, Math.floor(hex.length / 64)); w++) {
        const m = /^0{24}([0-9a-f]{40})$/.exec(hex.slice(hex.length - 64 * w, hex.length - 64 * (w - 1)));
        if (m && /[1-9a-f]/.test(m[1]) && nodeOf(chain, '0x' + m[1])) {
          const at = `initcode word -${w}`;
          addEdge(child, touch('0x' + m[1]), 'deploy', at, null, x, false, `${at} from the end`);
        }
      }
    }

    for (const leaf of ls) {
      const vals = leaf.type === 'address' && ADDR.test(String(leaf.value).trim()) ? [String(leaf.value).trim()]
        : leaf.type === '?' ? String(leaf.value).match(ADDR_IN) || [] : [];
      for (const v of vals) {
        if (/^0x0{40}$/.test(v)) continue;
        const rule = matchRule(isCreate ? null : fnName, leaf);
        const kind = isCreate ? 'deploy' : 'call';
        addEdge(source, touch(v), kind, label(leaf), rule, x, !fallback, `${leaf.path} = ${lc(v)}`);
      }
    }
  }

  // Factories' children.
  for (const n of nodes.values()) {
    if (!n.createdBy) continue;
    const x = out[n.created];
    const via = n.createdBy.via;
    const factory = `${n.chain}:${n.createdBy.factory}`;
    addEdge(factory, n.id, 'created', via ? 'created (CREATE3)' : 'created', null, x, true, via ? `via ${via}` : '');
    ensure(n.chain, n.createdBy.factory);
  }

  const renounced = replayControl(out, logsOf, nodeOf, ref, edges, stats);

  // Node kinds for what the deployment did not create.
  for (const n of nodes.values()) {
    if (n.kind === 'contract') continue;
    const called = (x) => x.type === 'CALL' && x.chain === n.chain && x.to === n.addr;
    if (n.sender) n.kind = 'sender';
    else if (out.some((x) => called(x) && x.status !== 'reverted')) {
      n.kind = 'outside-contract';
      n.name = n.name || (out.find((x) => called(x) && x.contractName) || {}).contractName || null;
    }
  }

  const stepIds = sprue ? sprueLayer(sprue, out, nodes, edges, warnings) : null;
  const steps = stepsOf(out, stepIds);
  for (const n of nodes.values()) {
    n.createdStep = n.created === null ? null : out[n.created].step;
    n.firstStep = n.created !== null ? n.createdStep : n.firstRef === Infinity ? 0 : out[n.firstRef].step;
  }

  const stepSpans = (spans) => spans.map(([a, b]) => [out[a].step, b === null ? null : out[b].step]);
  const edgeList = [...edges.values()].map(({ spansTx, holder, ...e }) => ({
    ...e,
    firstStep: Math.min(...e.txs.map((d) => out[d.i].step)),
    ...(spansTx ? { spans: stepSpans(spansTx) } : {}),
  }));
  const renouncedList = renounced.map(({ spansTx, holder, ...r }) => ({ ...r, spans: stepSpans(spansTx) }));

  nameOutside(nodes, edgeList, out);

  const { list: nodeList, lanes } = layout([...nodes.values()], out);
  stats.nodes = nodeList.length;
  stats.contracts = nodeList.filter((n) => n.kind === 'contract').length;
  stats.edges = edgeList.length;
  stats.control = edgeList.filter((e) => e.rule || (e.event && e.cls !== 'pending')).length;
  stats.controlEvents = edgeList.filter((e) => e.event && e.cls !== 'pending').length;
  stats.steps = steps.length;
  stats.reverted = out.filter((x) => x.status === 'reverted').length;
  stats.records = records.length;

  return {
    nodes: nodeList.map(({ refs, firstRef, created, createdBy, sender, lane, ...n }) => n),
    edges: edgeList,
    renounced: renouncedList,
    txs: out.map(({ arguments: _a, input, functionAbi, ...x }) => ({
      ...x,
      selector: input && input.length >= 10 ? input.slice(0, 10) : null,
      bytes: input ? (input.length - 2) / 2 : 0,
    })),
    steps,
    lanes,
    stats,
    warnings,
    sprue: !!sprue,
  };
}

// Reads a transaction's arguments, setting `x.fn` to the canonical signature (or the bare selector) when it
// learns one. `mode` says how: abi (calldata decoded against the signature), record (forge's argument strings,
// only when there is no calldata), positional (strings without types), raw (a selector with no known signature),
// failed (a signature that neither calldata nor strings could fill), none. `fallback` is set when positional
// strings stand in for calldata that did not decode.
function decode(x, isCreate, abis, knownSigs, nodeOf) {
  let fnName = null, trees = null, mode = 'none', fallback = false;

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
        trees = args.map((a, k) => ({
          type: { k: 'base', t: ADDR.test(String(a).trim()) ? 'address' : '?', name: `arg${k}` },
          value: String(a),
        }));
        mode = 'positional';
      }
    }
    return { fnName, trees, mode, fallback };
  }

  const sel = x.input && x.input.length >= 10 ? x.input.slice(0, 10).toLowerCase() : null;
  let sig = x.fn;
  if (!sig && sel) sig = knownSigs.get(sel) || abis.allSelectors().get(sel) || null;
  const parsed = sig && parseSignature(sig);
  if (!parsed) {
    if (sel) {
      x.fn = sel;
      mode = 'raw';
    }
    return { fnName, trees, mode, fallback };
  }

  fnName = parsed.name;
  x.fn = `${parsed.name}(${parsed.params.map(canonical).join(',')})`;
  const fromAbi = x.functionAbi && parseSignature(x.functionAbi);
  const params = withNames(
    parsed.params,
    fromAbi?.params || abis.functionParams(nodeOf(x.chain, x.to)?.name || x.contractName, x.fn)
      || COMMON.find((p) => commonSig(p) === x.fn)?.params,
  );

  // Calldata is what ran; forge's argument strings are read only when there is none.
  if (x.input) {
    try {
      trees = decTuple(params, x.input.slice(10), 0);
      mode = 'abi';
    } catch { trees = null; }
  } else if (x.arguments && x.arguments.length === params.length) {
    try {
      trees = params.map((t, k) => parseArgString(t, x.arguments[k]));
      mode = 'record';
    } catch { trees = null; }
  }

  if (!trees && x.arguments && x.arguments.length === params.length) {
    trees = params.map((t, k) => ({
      type: { k: 'base', t: t.k === 'base' ? t.t : '?', name: t.name ?? `arg${k}` },
      value: String(x.arguments[k]),
    }));
    mode = 'positional';
    fallback = !!x.input;
  }
  if (!trees && params.length === 0) mode = 'abi';
  if (!trees && params.length) mode = 'failed';
  return { fnName, trees, mode, fallback };
}

// One step per transaction, or per run of consecutive transactions with one sprue plan step id.
function stepsOf(out, stepIds) {
  const steps = [];
  for (const x of out) {
    const sid = stepIds && stepIds.get(x.i);
    const last = steps[steps.length - 1];
    if (sid && last && last.id === sid) last.txs.push(x.i);
    else steps.push({ id: sid || null, txs: [x.i] });
  }
  steps.forEach((s, k) => s.txs.forEach((i) => (out[i].step = k)));
  return steps;
}

// An outside address is named by how the records use it: the deployer, the parameter it was passed as, the
// factory of a child, or the call it received.
function nameOutside(nodes, edgeList, out) {
  const nameOf = (n) => n.role || n.name || n.label || n.addr.slice(0, 6) + '…' + n.addr.slice(-4);
  for (const n of nodes.values()) {
    if (n.kind === 'contract' || n.name) continue;
    if (n.kind === 'sender') { n.label = 'deployer'; continue; }

    const weight = (e) => (e.event && e.cls !== 'pending' ? 2 : e.rule ? 1 : 0);
    const into = edgeList.filter((e) => e.to === n.id && e.kind !== 'created')
      .sort((a, b) => weight(b) - weight(a) || a.firstStep - b.firstStep);
    const made = edgeList.find((e) => e.from === n.id && e.kind === 'created');
    const called = out.find((x) => x.type === 'CALL' && x.chain === n.chain && x.to === n.addr && x.fn);
    if (into.length) {
      const e = into[0], src = nameOf(nodes.get(e.from));
      const m = /^(\w+)\((.*)\)$/.exec(e.label);
      n.label = e.kind === 'event' || e.kind === 'impl' ? `${e.label} of ${src}`
        : e.kind === 'deploy' ? (/^initcode/.test(e.label) ? `in ${src} initcode` : `${e.label} of ${src}`)
          : m ? `${m[2]} via ${m[1]}` : `in ${e.label.split(' ')[0]} calldata`;
    } else if (made) n.label = `factory of ${nameOf(nodes.get(made.to))}`;
    else if (called) n.label = `target of ${called.fn.split('(')[0]}`;
  }
}

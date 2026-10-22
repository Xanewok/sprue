// SPDX-License-Identifier: MIT
// Runs in the page, serialised with its source text: it must use nothing outside its own body but `place`.
export function client(place) {
  const D = JSON.parse(document.getElementById('data').textContent);
  const G = D.geom;
  const $ = (s) => document.querySelector(s);
  const esc = (s) => String(s ?? '').replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);
  const short = (a) => (a ? a.slice(0, 6) + '…' + a.slice(-4) : '');
  const cut = (s, n) => (String(s).length > n ? String(s).slice(0, n - 1) + '…' : String(s));
  const clip = (s, n = 90) => (String(s).length > n ? String(s).slice(0, n) + `… (${String(s).length} chars)` : String(s));
  const byId = new Map(D.nodes.map((n) => [n.id, n]));
  // An event's link holds over its spans of steps; a link from the records' arguments holds from its first step on.
  const inSpans = (e, s) => e.spans.some(([a, b]) => a <= s && (b === null || s < b));
  const shownAt = (e, s) => (e.spans ? inSpans(e, s) : e.firstStep <= s);
  const isCtl = (e) => !!(e.rule || e.event) && e.cls !== 'pending';
  const ctlAt = (e, s) => isCtl(e) && shownAt(e, s);
  const outsideCtl = (e) => e.cls === 'authority' && isCtl(e) && byId.get(e.to).kind !== 'contract';
  const controllers = (id, s) => D.edges.filter((e) => e.from === id && outsideCtl(e) && shownAt(e, s));
  const sources = (e) => [e.event || e.impl ? `event ${e.event || e.impl}` : null, ...(e.rule ? [e.rule] : []).concat((e.names || []).map((m) => m.rule)).map((r) => `name rule ${r}`)].filter(Boolean);
  const spanText = (e) => e.spans.map(([a, b]) => (b === null ? `from step ${a + 1}` : b === a ? `set and ended in step ${a + 1}` : `steps ${a + 1}–${b}`)).join(', ');
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
  const nodeEls = new Map(), edgeEls = new Map(), markEls = new Map();
  const multiChain = new Set(D.nodes.map((n) => n.chain)).size > 1;
  // Fits an SVG text to a width: smaller type down to `min` px, then shortened, with the whole text as its tooltip.
  const fit = (t, text, w, min) => {
    t.textContent = text;
    const len = t.getComputedTextLength();
    if (len <= w) return;
    if (min) {
      t.style.fontSize = Math.max(min, Math.floor((parseFloat(getComputedStyle(t).fontSize) * w * 10) / len) / 10) + 'px';
      if (t.getComputedTextLength() <= w) return;
    }
    let n = text.length;
    while (n > 1 && (t.textContent = text.slice(0, --n) + '…') && t.getComputedTextLength() > w);
    el('title', {}, t).textContent = text;
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
    markEls.clear();
    const defs = el('defs', {}, svg);
    for (const [id, color] of [['arr', 'var(--edge)'], ['arrc', 'var(--accent)']]) {
      const m = el('marker', { id, viewBox: '0 0 10 10', refX: 9, refY: 5, markerWidth: 7, markerHeight: 7, orient: 'auto-start-reverse' }, defs);
      el('path', { d: 'M0,0 L10,5 L0,10 z', fill: color }, m);
    }
    const lanesG = el('g', {}, svg), edgesG = el('g', {}, svg), nodesG = el('g', {}, svg), labelsG = el('g', {}, svg);
    for (const l of L.lanes) {
      const lg = el('g', { class: 'lane' }, lanesG);
      el('rect', { x: l.x0, y: l.y0, width: l.x1 - l.x0, height: l.y1 - l.y0, rx: 8 }, lg);
      fit(el('text', { x: l.title.x, y: l.y0 + 16 }, lg), l.title.text, l.title.w);
    }
    for (const s of L.sides) {
      const lg = el('g', { class: 'lane side' }, lanesG);
      el('rect', { x: g.pad - 8, y: s.y0, width: g.w + 16, height: s.y1 - s.y0, rx: 8 }, lg);
      fit(el('text', { x: g.pad, y: s.y0 + 16 }, lg), `chain ${s.chain} · shared outside`, g.w);
    }

    for (const n of D.nodes) {
      const p = L.box.get(n.id);
      const cls = ['node', n.kind];
      if (n.certified) cls.push('cert');
      const ng = el('g', { class: cls.join(' '), tabindex: 0, role: 'button', 'aria-label': `${title(n)} ${n.addr}` }, nodesG);
      const inner = el('g', { transform: `translate(${p.x},${p.y})` }, ng);
      el('rect', { width: g.w, height: g.h, rx: 7 }, inner);
      // The lane title names the chain, so the name has the box's whole width.
      fit(el('text', { x: 9, y: 18 }, inner), title(n), g.w - 16, 10);
      const everCtl = D.edges.some((e) => e.from === n.id && outsideCtl(e));
      const marks = (everCtl ? 14 : 0) + (n.certified ? 14 : 0);
      fit(el('text', { x: 9, y: 35, class: 'addr' }, inner), short(n.addr) + (n.role && n.name ? ' · ' + n.name : ''), g.w - 16 - marks);
      if (everCtl) {
        const m = el('text', { x: g.w - (n.certified ? 30 : 16), y: 36, class: 'mark' }, inner);
        m.textContent = '⚑';
        el('title', {}, m).textContent = 'controlled by an outside address';
        markEls.set(n.id, m);
      }
      if (n.certified) el('text', { x: g.w - 16, y: 36, class: 'cert' }, inner).textContent = '✓';
      el('title', {}, ng).textContent = `${title(n)}\n${n.addr}\nchain ${n.chain} · ${kindText[n.kind]}`;
      ng.addEventListener('mouseenter', () => hover({ node: n.id }));
      ng.addEventListener('mouseleave', () => hover(null));
      ng.addEventListener('click', (e) => { e.stopPropagation(); select({ node: n.id }); });
      ng.addEventListener('keydown', (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); select({ node: n.id }); } });
      nodeEls.set(n.id, ng);
    }

    // One drawn link per ordered pair; apply() styles it as its strongest edge at the step.
    for (const r of [...L.routes].sort((a, b) => a.edges.some(isCtl) - b.edges.some(isCtl))) {
      const eg = el('g', { class: 'edge' + (D.sprue && r.edges.some((e) => e.verified) ? ' verified' : '') }, edgesG);
      const d = rounded(r.pts);
      const path = el('path', { d }, eg);
      el('path', { d, class: 'hit' }, eg);
      const text = r.edges.length === 1 ? r.edges[0].label + (r.edges[0].rule ? ` [${r.edges[0].rule}]` : '') : `${r.edges.length} links: ${r.edges.map((e) => e.label).join(', ')}`;
      const lt = el('text', { 'text-anchor': 'middle', class: 'elabel' }, labelsG);
      lt.textContent = cut(text, 46);
      el('title', {}, eg).textContent = `${title(byId.get(r.from))} → ${title(byId.get(r.to))}\n${r.edges.map((e) => e.label + (sources(e).length ? ` (${sources(e).join(', ')})` : '') + (e.verified ? ' (certificate-verified)' : '')).join('\n')}`;
      eg.addEventListener('mouseenter', () => hover({ link: r.key }));
      eg.addEventListener('mouseleave', () => hover(null));
      eg.addEventListener('click', (ev) => { ev.stopPropagation(); select({ link: r.key }); });
      edgeEls.set(r.key, { g: eg, path, label: lt, r });
    }
    for (const b of L.badges) {
      const bg = el('g', { class: 'badge', 'data-node': b.to || b.from }, labelsG);
      el('circle', { cx: b.x, cy: b.y, r: 8 }, bg);
      el('text', { x: b.x, y: b.y + 3.5, 'text-anchor': 'middle' }, bg).textContent = b.n;
      el('title', {}, bg).textContent = b.to ? `${b.n} links merge here into ${title(byId.get(b.to))}` : `${b.n} links leave ${title(byId.get(b.from))} here as one bus`;
    }
  }

  // The page opens on the whole deployment; a step's marks appear once the reader moves.
  const S = { step: D.steps.length - 1, sel: null, lens: true, moved: false, list: false };
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
    return `<h3>${esc(title(a))} → ${esc(title(b))}</h3><div>${{ deploy: 'set at deploy', call: 'set by call', created: 'created by', event: 'emitted', impl: 'emitted' }[e.kind]}: <code>${esc(e.label)}</code>
      ${pills(e)}${D.sprue ? (e.verified ? '<span class="pill ok">certificate-verified</span>' : '<span class="pill">not certified</span>') : ''}
      ${e.decoded ? '' : '<span class="pill bad">found in raw calldata</span>'}</div>${e.names ? `<div class="muted">also ${e.names.map((m) => esc(m.label)).join(', ')}</div>` : ''}${e.spans ? `<div class="muted">holds ${spanText(e)}</div>` : ''}${e.txs.map((d) => txLine(d.i, d.detail)).join('')}`;
  }
  function pills(e) {
    return (e.cls === 'pending' ? '<span class="pill">pending, not control</span>' : '') + sources(e).map((t) => `<span class="pill ctl">${esc(t)}</span>`).join('');
  }
  function panel() {
    const P = $('#panel');
    if (S.sel && S.sel.node) {
      const n = byId.get(S.sel.node);
      const es = D.edges.filter((e) => e.from === n.id || e.to === n.id);
      const made = D.txs.find((x) => x.created.includes(n.id));
      const ctlNow = controllers(n.id, S.step);
      const impls = D.edges.filter((e) => e.kind === 'impl' && e.from === n.id && shownAt(e, S.step));
      P.innerHTML = `<h2>${esc(title(n))}</h2><div><code>${esc(n.addr)}</code></div><div class="muted">chain ${n.chain} · ${esc(kindText[n.kind])}${n.name && n.role ? ' · ' + esc(n.name) : ''}</div>
        ${n.certified ? '<div><span class="pill ok">certified in its journal</span></div>' : ''}
        ${ctlNow.length ? `<div><span class="pill ctl">controlled by an outside address</span> ${ctlNow.map((e) => `${esc(title(byId.get(e.to)))} (${esc(e.label)}; ${esc(sources(e).join(', '))})`).join(', ')}</div>` : ''}
        ${impls.map((e) => `<div><span class="pill">${esc(e.label)}</span> <a href="#" data-node="${esc(e.to)}"><b>${nameOf(e.to)}</b></a> <code>${esc(short(byId.get(e.to).addr))}</code></div>`).join('')}
        ${D.renounced.filter((r) => r.from === n.id && inSpans(r, S.step)).map((r) => `<div><span class="pill">${esc(r.label)} renounced</span> ${spanText(r)} (event ${esc(r.event)})</div>`).join('')}
        ${made ? `<h3>Created</h3>${txLine(made.i)}` : ''}${es.length ? es.map(edgeBlock).join('') : '<p class="muted">No links.</p>'}`;
    } else if (S.sel && S.sel.link) {
      P.innerHTML = linkBlock(S.sel.link);
    } else {
      const s = D.stats;
      P.innerHTML = `<h2>Deployment</h2><p>${s.contracts} contracts created, ${s.nodes - s.contracts} outside addresses, ${s.edges} links (${s.control} for control: ${s.controlEvents} from events, ${s.control - s.controlEvents} from names), ${s.steps} steps${s.reverted ? `, ${s.reverted} reverted` : ''}.</p>
        ${D.warnings.map((w) => `<p class="rev">${esc(w)}</p>`).join('')}
        <h3>Step ${S.step + 1}: what changed</h3>${stepChanges(S.step)}
        <h3>Who controls what at step ${S.step + 1}</h3>${controls(S.step)}
        <p class="muted">Control comes from the events the chain emitted (ownership, roles, proxy admin) and else from function and parameter names, a heuristic. Each line names its source. Select a line, an address or a link for the transactions behind it.</p>`;
    }
  }
  const nameOf = (id) => esc(title(byId.get(id)));
  const linkKey = (e) => e.from + '>' + e.to;
  // One line per change, newest state first: what the step created, then each link it set or ended. A repeated
  // line gets its count at the \u0001 mark, else at its end.
  function stepChanges(k) {
    const lines = [];
    for (const i of D.steps[k].txs) {
      const x = D.txs[i];
      const fn = x.type === 'CALL' ? (x.fn ? x.fn.split('(')[0] : 'call without data') : x.type;
      if (x.status === 'reverted') lines.push(`<li class="rev">${esc(fn)} reverted: nothing created or bound</li>`);
      for (const id of x.created) lines.push(`<li><a href="#" data-node="${esc(id)}">+ ${nameOf(id)}</a> created</li>`);
      let any = x.created.length > 0;
      for (const e of D.edges)
        for (const d of e.kind === 'created' ? [] : e.txs.filter((d) => d.i === i)) {
          any = true;
          lines.push(`<li><a href="#" data-link="${esc(linkKey(e))}">${d.gone ? '− ' : ''}${nameOf(e.from)} · ${esc(e.label)} → ${nameOf(e.to)}</a>${d.gone ? ' ended' : ' ' + pills(e)}</li>`);
        }
      for (const r of D.renounced)
        if (r.txs.some((d) => d.i === i && !d.gone)) {
          any = true;
          lines.push(`<li><a href="#" data-node="${esc(r.from)}">${nameOf(r.from)} · ${esc(r.label)} renounced</a> <span class="pill">event ${esc(r.event)}</span></li>`);
        }
      if (!any && x.status !== 'reverted') lines.push(`<li class="muted">${esc(fn)}\u0001 on ${nameOf(`${x.chain}:${x.to}`)}</li>`);
    }
    const seen = new Map();
    for (const l of lines) seen.set(l, (seen.get(l) || 0) + 1);
    const count = (l, n) => (l.includes('\u0001') ? l.replace('\u0001', n > 1 ? ` ×${n}` : '') : n > 1 ? l.replace(/<\/li>$/, ` ×${n}</li>`) : l);
    return `<ul class="changes">${[...seen].map(([l, n]) => count(l, n)).join('')}</ul>`;
  }
  // The handover question: each address that holds control at step s, and what it holds; outside addresses first.
  function controls(s) {
    const by = new Map();
    for (const e of D.edges) if (ctlAt(e, s) || (e.cls === 'pending' && shownAt(e, s))) (by.get(e.to) || by.set(e.to, []).get(e.to)).push(e);
    const gone = D.renounced.filter((r) => inSpans(r, s));
    if (!by.size && !gone.length) return '<p class="muted">No control event or name rule at this step.</p>';
    const since = (e) => (e.spans ? e.spans.filter(([a]) => a <= s).pop()[0] : e.firstStep) + 1;
    const order = [...by.keys()].sort((a, b) => (byId.get(a).kind === 'contract') - (byId.get(b).kind === 'contract'));
    return `<ul class="changes">${order.map((id) => `<li><a href="#" data-node="${esc(id)}"><b>${nameOf(id)}</b></a> <code>${esc(short(byId.get(id).addr))}</code>${multiChain ? ` <span class="muted">chain ${byId.get(id).chain}</span>` : ''}${byId.get(id).kind === 'contract' ? '' : ' <span class="pill">outside</span>'}<ul>${by.get(id).map((e) => `<li><a href="#" data-link="${esc(linkKey(e))}">${nameOf(e.from)} · ${esc(e.label)}</a> ${pills(e)} <span class="muted">step ${since(e)}</span></li>`).join('')}</ul></li>`).join('')}${gone.length ? `<li><b>renounced</b><ul>${gone.map((r) => `<li><a href="#" data-node="${esc(r.from)}">${nameOf(r.from)} · ${esc(r.label)}</a> <span class="pill">event ${esc(r.event)}</span> <span class="muted">step ${r.spans.filter(([a]) => a <= s).pop()[0] + 1}</span></li>`).join('')}</ul></li>` : ''}</ul>`;
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
    svg.classList.toggle('lens', S.lens && D.edges.some(isCtl));
    const stepTx = new Set(D.steps[s].txs);
    const reverted = D.steps[s].txs.filter((i) => D.txs[i].status === 'reverted');
    for (const n of D.nodes) {
      const g = nodeEls.get(n.id);
      g.classList.toggle('future', n.firstStep > s);
      g.classList.toggle('now', S.moved && n.createdStep === s);
      g.classList.toggle('revnow', reverted.some((i) => `${D.txs[i].chain}:${D.txs[i].to}` === n.id));
      g.classList.toggle('sel', !!(S.sel && S.sel.node === n.id));
      const ctl = controllers(n.id, s).length > 0;
      g.classList.toggle('ctl', ctl && S.lens);
      markEls.get(n.id)?.classList.toggle('hidden', !ctl);
      g.classList.remove('hot');
    }
    const rank = { event: 3, impl: 3, deploy: 2, call: 1, created: 0 };
    for (const { g, path, label, r } of edgeEls.values()) {
      const vis = r.edges.filter((e) => shownAt(e, s));
      const kind = vis.reduce((a, e) => (rank[e.kind] > rank[a] ? e.kind : a), (vis[0] || r.edges[0]).kind);
      const ctl = vis.some((e) => ctlAt(e, s));
      for (const k in rank) g.classList.toggle(k, k === kind);
      g.classList.toggle('ctl', ctl);
      g.classList.toggle('pending', kind === 'event' && !ctl);
      path.setAttribute('marker-end', kind === 'event' || (ctl && S.lens) ? 'url(#arrc)' : 'url(#arr)');
      const now = S.moved && vis.some((e) => e.txs.some((d) => stepTx.has(d.i)));
      for (const x of [g, label]) {
        x.classList.toggle('future', !vis.length);
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
      const binds = D.edges.filter((e) => e.kind !== 'created' && e.txs.some((d) => d.i === i && !d.gone)).length;
      return `${what}${made}${binds ? ` · binds ${binds} link${binds > 1 ? 's' : ''}` : ''}${x.status === 'reverted' ? ' · <span class="rev">reverted: created and bound nothing</span>' : ''}`;
    });
    const head = `${st.id ? `<b>${esc(st.id)}</b> · ` : ''}${esc(D.txs[st.txs[0]].script)} · `;
    if (parts.length === 1) {
      $('#stepinfo').innerHTML = head + parts[0];
      return;
    }
    // Several transactions: one summary line, so the map does not jump while stepping; the list on demand.
    const xs = st.txs.map((i) => D.txs[i]), kinds = new Map();
    for (const x of xs) {
      const k = x.type === 'CALL' ? (x.fn || '(no data)').split('(')[0] : `${x.type} ${x.contractName || ''}`.trim();
      kinds.set(k, (kinds.get(k) || 0) + 1);
    }
    const made = xs.reduce((a, x) => a + x.created.length, 0), rev = xs.filter((x) => x.status === 'reverted').length;
    const binds = D.edges.filter((e) => e.kind !== 'created' && e.txs.some((d) => stepTx.has(d.i) && !d.gone)).length;
    const what = [...kinds].slice(0, 3).map(([k, n]) => esc(k) + (n > 1 ? ` ×${n}` : '')).join(', ') + (kinds.size > 3 ? `, +${kinds.size - 3} more` : '');
    $('#stepinfo').innerHTML = `<details${S.list ? ' open' : ''}><summary>${head}<b>${xs.length} transactions</b>: ${what}${made ? ` · creates ${made}` : ''}${binds ? ` · binds ${binds} link${binds > 1 ? 's' : ''}` : ''}${rev ? ` · <span class="rev">${rev} reverted</span>` : ''}</summary><ol class="txlist">${parts.map((p) => `<li>${p}</li>`).join('')}</ol></details>`;
    $('#stepinfo details').ontoggle = (e) => (S.list = e.target.open);
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
    panel();
  };
  // Sections: runs of steps from one script. Every step has a script, while only some have a sprue unit.
  const sections = [];
  D.steps.forEach((st, k) => {
    const name = D.txs[st.txs[0]].script;
    const last = sections[sections.length - 1];
    if (last && last.name === name) last.end = k;
    else sections.push({ name, start: k, end: k });
  });
  const secOf = (k) => sections.findIndex((x) => k >= x.start && k <= x.end);
  // A section shows its script without what every script shares (`Deploy`, `MU01-`, `.s.sol`), else its
  // first words, else its initials, else nothing; the tooltip has the whole name.
  const bare = (n) => n.replace(/(\.s)?\.sol$/, '');
  const names = [...new Set(sections.map((x) => bare(x.name)))];
  const wordStart = (n, i) => /[-_. ]/.test(n[i - 1]) || (/[A-Z]/.test(n[i]) && /[a-z0-9]/.test(n[i - 1]));
  let pre = 0;
  if (names.length > 1) {
    while (names.every((n) => pre < n.length - 1 && n[pre] === names[0][pre])) pre++;
    while (pre > 0 && !names.every((n) => wordStart(n, pre))) pre--;
  }
  const forms = (label) => {
    const starts = [...label].map((_, i) => i).filter((i) => i > 0 && wordStart(label, i));
    const words = label.match(/[A-Z]?[a-z]+|[A-Z]+(?![a-z])|\d+/g) || [];
    return [label, ...starts.slice(1).reverse().map((i) => label.slice(0, i).replace(/[-_. ]+$/, '') + '…'),
      words.map((w) => (/^\d/.test(w) ? w : w[0].toUpperCase())).join(''), ''];
  };
  const fitSections = () => document.querySelectorAll('.sec').forEach((b) => {
    for (const t of forms(b.dataset.label)) {
      b.textContent = t;
      if (b.scrollWidth <= b.clientWidth) break;
    }
  });
  $('#sections').append(...sections.map((x) => {
    const b = document.createElement('button');
    b.className = 'sec';
    b.style.flexGrow = x.end - x.start + 1;
    b.dataset.label = bare(x.name).slice(pre);
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
    resizing = setTimeout(() => { draw(); apply(); fitSections(); }, 120);
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
  tabs.map.onclick = () => { show('map'); fitSections(); };
  tabs.table.onclick = () => show('table');
  draw();
  apply();
  panel();
  fitSections();
}

// SPDX-License-Identifier: MIT
// Where the map's boxes sit and where its links run. `layout` fixes lane order and node rank, which do not depend
// on the page; `place` turns them into coordinates for one page width.
//
// `place` maintains, for the width it is given:
//   Links run only in the gaps between rows, lanes and columns, so no link is drawn through a box.
//   Links into one node merge into one trunk and links out of one node into one bus; each trunk or bus owns a
//   track of every channel it uses, and a channel widens until its tracks fit, so parallel links never draw
//   over each other. Widening stops after 21 rounds. A result wider than the page drops a column at a time
//   down to two, then narrows the boxes to at least 112px, and may still be wider.
//   Positions depend on the deployment and the width only, never on the step shown.
// Relies on `layout` having set `laneKey` and `ord` on the nodes.

// Box and gap sizes in px; the page's width decides how many columns fit.
export const GEOM = { w: 190, h: 46, gx: 44, gy: 34, laneGap: 52, cols: 8, pad: 24, title: 22 };

export function layout(list, out) {
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

// Runs in the page, serialised with its source text (`client.mjs` receives it as an argument), so it must use
// nothing outside its own body: its helpers are nested functions, not module-level ones.
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
    const linked = [...nbrs.get(n.id)].map((id) => byId.get(id));
    const into = new Set(linked.filter((m) => m.kind === 'contract').map((m) => m.laneKey));
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

  // Widened gaps can overflow the width: then one column fewer, down to two, then narrower boxes, down to 112px.
  for (let cols = fit; ; cols--) {
    const L = attempt(cols);
    if (L.W <= avail) return L;
    if (cols <= Math.min(2, fit)) {
      const w = Math.max(112, g.w - Math.ceil((L.W - avail) / cols));
      if (w === g.w) return L;
      g.w = w;
      return attempt(cols);
    }
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
    // `prev` is the channel below the last shelf placed: the next shelf takes it as its channel above, so two
    // shelves share one gap. It is null where a side column pushed `y` past the last shelf.
    let y = g.pad - g.laneGap / 2, k = 0, prev = null;
    for (const chain of [...new Set(D.lanes.map((key) => key.split('|')[0]))]) {
      let top = null;
      for (const l of shelves.filter((s) => s.chain === chain)) {
        l.rows = Math.max(...l.lanes.map((m) => m.rows));
        const above = prev || chan('b' + k++, y, g.laneGap);
        const y0 = above.y + above.w / 2;
        if (top === null) top = y0;
        // The title band sits above the shelf's top channel, so only links between shelves cross it, in the gaps.
        const tc = chan('t' + k, y0 + g.title, 12);
        const rowTop = [], inner = [];
        let ry = tc.y + tc.w / 2;
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
        l.above = (r) => (r === 0 ? tc : inner[r - 1]);
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
    // The offset of `by`'s track in a channel: the first user runs on the centre line, the next ones alternate
    // either side. Everything with the same `by` shares one track, which is what merges a trunk or a bus.
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
        const up = cy(B) < cy(A), sx = port(A, up, true);
        const yc = h(up ? A.shelf.above(A.row) : A.shelf.below(A.row), S), xg = v(0);
        pts = [[sx, up ? A.y : A.y + g.h], [sx, yc], [xg, yc], [xg, cy(B) + 6], [B.x + g.w, cy(B) + 6]];
      } else if (A.side) {
        const down = cy(B) > cy(A), ex = port(B, down, false);
        const yc = h(down ? B.shelf.above(B.row) : B.shelf.below(B.row)), xg = v(0, S);
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
        const c1 = down ? A.shelf.below(A.row) : A.shelf.above(A.row);
        const c2 = down ? B.shelf.above(B.row) : B.shelf.below(B.row);
        const aEdge = down ? A.y + g.h : A.y, bEdge = down ? B.y : B.y + g.h;
        const sx = port(A, !down, true), ex = port(B, down, false);
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
      routes.push({ ...bd, pts });
    }

    // A trunk's count sits at its shared entry point.
    const entries = new Map();
    for (const r of routes) {
      const k = r.to + '@' + r.pts[r.pts.length - 1].join(',');
      if (!entries.has(k)) entries.set(k, { to: r.to, n: 0, a: r.pts[r.pts.length - 1], b: r.pts[r.pts.length - 2] });
      entries.get(k).n++;
    }
    const badgeAt = (e) => ({ n: e.n, x: (e.a[0] + e.b[0]) / 2, y: (e.a[1] + e.b[1]) / 2 });
    const badges = [...entries.values()].filter((e) => e.n >= 3).map((e) => ({ to: e.to, ...badgeAt(e) }));

    const exits = new Map();
    for (const r of routes) {
      const k = r.from + '@' + r.pts[0].join(',');
      if (!exits.has(k)) exits.set(k, { from: r.from, n: 0, a: r.pts[0], b: r.pts[1] });
      exits.get(k).n++;
    }
    for (const e of exits.values()) if (e.n >= 4) badges.push({ from: e.from, ...badgeAt(e) });

    const maxUsed = Math.max(0, ...[...cell.values()].map((p) => p.c)) + 1;
    const W = Math.max(Math.min(avail, 440), gapC[maxUsed] + vw[maxUsed] / 2 + g.pad);
    const H = Math.max(prev ? prev.y + prev.w / 2 : y, ...sides.map((s) => s.y1 + 10)) + g.pad / 2;
    const counts = new Map([...tracks].map(([key, l]) => [key, l.length]));

    // A lane's title goes in the leftmost stretch of its band that no link crosses and that holds it whole, else
    // in the widest one, where the page shortens it.
    const lanes = laneList.map((l) => {
      const cs = l.nodes.map((n) => cell.get(n.id).c);
      const x0 = colX[Math.min(...cs)] - 12, x1 = colX[Math.max(...cs)] + g.w + 12, y0 = l.shelf.y0;
      const [chain, script] = l.key.split('|'), text = `chain ${chain} · ${script}`;
      const band = [y0 + 3, y0 + g.title - 3];
      const cuts = routes.flatMap((r) => r.pts.slice(1).map((p, i) => [r.pts[i], p]))
        .filter(([a, b]) => Math.max(a[1], b[1]) > band[0] && Math.min(a[1], b[1]) < band[1])
        .map(([a, b]) => [Math.min(a[0], b[0]) - 4, Math.max(a[0], b[0]) + 4])
        .concat(badges.filter((b) => b.y + 9 > band[0] && b.y - 9 < band[1]).map((b) => [b.x - 13, b.x + 13]))
        .sort((a, b) => a[0] - b[0]);
      const free = [];
      let at = x0 + 10;
      for (const [a, b] of cuts) {
        if (a > at) free.push([at, Math.min(a, x1 - 10)]);
        at = Math.max(at, b);
      }
      if (at < x1 - 10) free.push([at, x1 - 10]);
      const need = text.length * 6.8;
      const widest = free.reduce((m, f) => (f[1] - f[0] > m[1] - m[0] ? f : m), [x0 + 10, x0 + 10]);
      const spot = free.find(([a, b]) => b - a >= need) || widest;
      const title = { text, x: spot[0], y: band[0], w: spot[1] - spot[0], h: band[1] - band[0] };
      return { key: l.key, x0, x1, y0, y1: l.shelf.y1, title };
    });
    return { g, W, H, cols, box, routes, badges, lanes, sides, counts, width };
  }
}

// SPDX-License-Identifier: MIT
// The page: a model drawn as one HTML file with its style, data and script inline, so it loads nothing.
//
// The model is embedded as JSON in a script element with `<` escaped, so text from the records cannot close the
// element; U+2028 and U+2029, which end a line in a JS string literal, are escaped too. The script is `client`
// called with `place`, both serialised with `toString()`.

import { client } from './client.mjs';
import { GEOM, place } from './layout.mjs';

export function render(model, title) {
  const data = JSON.stringify({ ...model, geom: GEOM })
    .replace(/</g, '\\u003c')
    .replace(/[\u2028\u2029]/g, (c) => '\\u' + c.charCodeAt(0).toString(16));
  const escapes = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' };
  const esc = (s) => String(s).replace(/[&<>"]/g, (c) => escapes[c]);
  const s = model.stats;
  const scripts = [...new Set(model.txs.map((x) => x.script))];

  const swatch = (attrs, text) =>
    `<span><svg width="28" height="10"><path d="M0,5 H28" ${attrs}/></svg> ${text}</span>`;
  const legend = [
    '<details id="legend" open><summary>Legend</summary><div class="legend">',
    swatch('stroke="var(--edge)" stroke-dasharray="1 3" stroke-linecap="round" stroke-width="1.5"', 'created by'),
    swatch('stroke="var(--edge)" stroke-width="1.5"', 'set at deploy'),
    swatch('stroke="var(--edge)" stroke-dasharray="6 3" stroke-width="1.5"', 'set by call'),
    swatch('stroke="var(--accent)" stroke-width="2"',
      'control: from an event (owner, role, proxy admin), else a name rule'),
    swatch('stroke="var(--accent)" stroke-dasharray="2 3" stroke-width="2"', 'pending owner'),
    swatch('stroke="var(--accent2)" stroke-dasharray="9 3 2 3" stroke-width="2"',
      'implementation or beacon of a proxy, not control'),
    `<span>⚑ controlled by an outside address</span>${model.sprue
      ? '<span>✓ certified role; thick solid line: certificate-verified link</span>' : ''}`,
    '<span>dashed box: not created by this deployment</span><span>a number: links merging into one entry</span>'
      + '<span>labels show on hover, on selection and for the current step</span></div></details>',
  ].join('\n');

  const header = `<header><h1 title="${esc(scripts.join(', '))}">${esc(title)}</h1>`
    + (scripts.length > 1 ? `<p>Scripts: ${esc(scripts.join(', '))}.</p>` : '')
    + `<p>${s.contracts} contracts, ${s.nodes - s.contracts} outside addresses, ${s.edges} links, ${s.steps} steps, `
    + `from ${s.records} broadcast record files. Built offline from forge's records; `
    + 'links show what the records say, not what the chain holds now.</p></header>';

  return [
    '<!doctype html>',
    '<html lang="en"><head><meta charset="utf-8">'
      + '<meta name="viewport" content="width=device-width,initial-scale=1">',
    `<meta name="color-scheme" content="light dark"><title>${esc(title)}</title><style>${CSS}</style>`
      + '</head>',
    `<body>${header}`,
    '<div class="bar" id="topbar"><button class="tab" id="tab-map" aria-selected="true">Map</button>'
      + '<button class="tab" id="tab-table" aria-selected="false">Table</button>',
    '<span id="playbar" style="display:contents">'
      + '<button id="first" aria-label="first step">⏮</button>'
      + '<button id="prev" aria-label="previous step">◀</button><span id="count" aria-live="polite">'
      + '</span><button id="next" aria-label="next step">▶</button>'
      + '<button id="lastb" aria-label="last step">⏭</button>',
    '<span id="scrubwrap">'
      + '<input id="scrub" type="range" min="0" step="1" aria-label="step" '
      + 'title="Arrow keys: step; PageUp/PageDown: section; Home/End: section start/end">'
      + '<span id="sections"></span></span><label class="chk">'
      + '<input type="checkbox" id="lens" checked> control lens</label></span>'
      + '<button id="paneltoggle" aria-pressed="true" aria-controls="panel">Panel</button></div>',
    `<div id="mapview"><div id="stepinfo" aria-live="polite"></div>${legend}<main><div id="mapwrap">`
      + '</div><aside id="panel" aria-live="polite"></aside></main></div>',
    '<section id="tableview" class="hidden">'
      + '<input id="filter" type="search" placeholder="Filter transactions" aria-label="Filter transactions">',
    '<table>'
      + '<caption class="muted" style="text-align:left">One row per transaction, in order.</caption>'
      + '<thead><tr><th>Step</th><th>Script</th><th>Type</th><th>Target</th><th>Function</th>'
      + '<th>Arguments</th><th>Status</th><th>Hash</th></tr></thead><tbody id="tbody"></tbody></table>'
      + '</section>',
    `<script type="application/json" id="data">${data}</script>`,
    `<script>(${client.toString()})(${place.toString()});</script></body></html>`,
  ].join('\n') + '\n';
}

// A trailing backslash continues a line of the template without adding a newline to the CSS.
const CSS = `
:root{--bg:#fbfbfa;--fg:#1d1f23;--muted:#666b73;--line:#d9dbe0;--panel:#ffffff;--node:#ffffff;--outside:#f1efe8;\
--sender:#ece9f7;
--edge:#8b919b;--accent:#b4400f;--accent2:#1f6fb2;--new:#0f8a4b;--bad:#c0261d;--lane:#f2f3f5;\
--shadow:0 1px 2px rgba(0,0,0,.08)}
@media (prefers-color-scheme:dark){:root{--bg:#15171a;--fg:#e6e7ea;--muted:#9aa0a9;--line:#33373e;--panel:#1c1f23;\
--node:#22262b;
--outside:#2a2823;--sender:#28253a;--edge:#7d838d;--accent:#f08a4b;--accent2:#6aaef0;--new:#44c983;--bad:#f2665c;\
--lane:#1a1d21;--shadow:none}}
*{box-sizing:border-box}html,body{margin:0;background:var(--bg);color:var(--fg);\
font:14px/1.4 system-ui,-apple-system,Segoe UI,sans-serif}
header{padding:12px 16px 4px}h1{font-size:17px;margin:0 0 2px}header p{margin:0;color:var(--muted);font-size:12.5px}
.bar{display:flex;flex-wrap:wrap;gap:8px;align-items:center;padding:8px 16px;border-bottom:1px solid var(--line);\
position:sticky;top:0;background:var(--bg);z-index:2}
button,.tab{font:inherit;color:inherit;background:var(--panel);border:1px solid var(--line);border-radius:6px;\
padding:4px 10px;cursor:pointer}
button:focus-visible,input:focus-visible{outline:2px solid var(--accent2);outline-offset:1px}
.tab[aria-selected=true]{border-color:var(--fg);font-weight:600}
#count{font-variant-numeric:tabular-nums;min-width:5.5em;text-align:center}
#scrubwrap{flex:1 1 160px;min-width:120px;display:flex;flex-direction:column;gap:2px}#scrub{width:100%;margin:0}
#sections{display:flex;gap:2px;height:15px}.sec{flex:1 1 0;min-width:3px;padding:0 4px;font-size:10px;\
line-height:15px;overflow:hidden;white-space:nowrap;text-overflow:ellipsis;border-radius:3px;background:var(--lane);\
border:0;color:var(--muted);text-align:left}
.sec.cur{background:var(--accent2);color:var(--bg)}
main.nopanel #panel{display:none}#paneltoggle[aria-pressed=false]{opacity:.7}
#legend{padding:0 16px 4px;font-size:12px;color:var(--muted)}#legend summary{cursor:pointer;width:max-content}
ul.changes{margin:4px 0 8px;padding-left:16px}ul.changes li{margin:2px 0}ul.changes ul{padding-left:14px}\
#panel a{color:inherit;text-decoration:none;border-bottom:1px dotted var(--muted)}
label.chk{display:flex;gap:4px;align-items:center;font-size:13px}
#stepinfo{padding:6px 16px;font-size:13px;color:var(--muted);min-height:2.2em}
#stepinfo b{color:var(--fg)}#stepinfo summary{cursor:pointer}ol.txlist{margin:2px 0 0;padding-left:22px}\
.rev{color:var(--bad);font-weight:600}
main{display:flex;gap:0;align-items:stretch}
#mapwrap{flex:1 1 auto;overflow:auto;min-height:420px;max-height:calc(100vh - 150px)}
#panel{flex:0 0 340px;border-left:1px solid var(--line);background:var(--panel);padding:12px 14px;overflow:auto;\
max-height:calc(100vh - 150px);font-size:13px}
#panel h2{font-size:14px;margin:0 0 6px}#panel h3{font-size:13px;margin:12px 0 4px}
#panel .tx{border-top:1px solid var(--line);padding:6px 0}#panel code,td code{font:12px ui-monospace,SFMono-Regular,\
Menlo,monospace;word-break:break-all}
.muted{color:var(--muted)}.pill{display:inline-block;font-size:11px;padding:0 6px;border-radius:9px;\
border:1px solid var(--line);margin-right:4px}
.pill.ctl{border-color:var(--accent);color:var(--accent)}.pill.bad{border-color:var(--bad);color:var(--bad)}\
.pill.ok{border-color:var(--new);color:var(--new)}
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
.edge path{fill:none;stroke:var(--edge);stroke-width:1.3;opacity:.75}\
.edge.created path{stroke-dasharray:1 3;stroke-linecap:round}
.edge.call path{stroke-dasharray:6 3}.edge.verified path{stroke-dasharray:none;stroke-width:2}
.lens .edge path{opacity:.45}.lens .edge.ctl path{opacity:1;stroke:var(--accent);stroke-width:2}
.edge.impl path{stroke:var(--accent2);stroke-width:2;stroke-dasharray:9 3 2 3}\
.edge.event path{stroke:var(--accent);stroke-width:2}.edge.event.pending path{stroke-dasharray:2 3}
.elabel{font-size:11px;fill:var(--fg);paint-order:stroke;stroke:var(--bg);stroke-width:4px;stroke-linejoin:round;\
display:none;pointer-events:none}
.elabel.shown{display:block}
.edge.now path{stroke:var(--new);stroke-width:2.6;opacity:1}.edge.future{display:none}
.edge.hot path{opacity:1;stroke-width:2.4}.edge{cursor:pointer}\
.edge path.hit{stroke:transparent;stroke-width:10;opacity:0}
.edge path{stroke-linejoin:round}
.badge circle{fill:var(--panel);stroke:var(--edge)}.badge.future{opacity:.18}\
.badge text{font-size:10px;font-weight:600}
.dim .node:not(.hot){opacity:.15}.dim .edge:not(.hot){opacity:.08}.dim .badge{opacity:.15}
@keyframes pop{0%{transform:scale(.6)}60%{transform:scale(1.08)}100%{transform:scale(1)}}
.anim .node.now>g{animation:pop .35s ease-out;transform-box:fill-box;transform-origin:center}
@media (prefers-reduced-motion:reduce){.anim .node.now>g{animation:none}.node{transition:none}}
#tableview{padding:0 16px 24px;overflow:auto}#tableview input{font:inherit;padding:4px 8px;margin:8px 0;\
width:min(420px,100%);border:1px solid var(--line);border-radius:6px;background:var(--panel);color:var(--fg)}
table{border-collapse:collapse;width:100%;font-size:12.5px}th,td{text-align:left;vertical-align:top;\
border-bottom:1px solid var(--line);padding:5px 6px}
th{position:sticky;top:0;background:var(--bg)}tr.reverted td{color:var(--bad)}
.legend{display:flex;flex-wrap:wrap;gap:10px;padding:4px 0 6px}
.legend svg{display:inline-block;vertical-align:middle}
.hidden{display:none!important}
@media (max-width:760px){main{flex-direction:column}#panel{flex:none;border-left:0;border-top:1px solid var(--line);\
max-height:none}#mapwrap{max-height:70vh}}
@media print{.bar,#mapwrap,#panel,#legend,#stepinfo{display:none!important}#tableview{display:block!important}}
`;

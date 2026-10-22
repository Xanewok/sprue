// SPDX-License-Identifier: MIT
// A static HTML map of a Foundry deployment, from forge's broadcast records. `sprue map`; see MAP.md.
import { existsSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { join, basename, dirname, resolve } from 'node:path';

import { build } from './model.mjs';
import { render } from './page.mjs';

export { keccak256 } from './abi.mjs';
export { GEOM, place } from './layout.mjs';
export { build, render };

export const USAGE = `usage: sprue map [--records <path>]... [--out <file>] [--title <text>] [<network>]

Draws what a Foundry deployment created and how the contracts connect, as one HTML page that loads nothing.
It reads forge's broadcast records; sprue's journals are an add-in.

  <network>         add role names, certificate-verified links and step ids from the journals of that network
                    (<paths.deployments>/<network> of sprue.json); the project must have sprue.json
  --records <path>  a broadcast directory or record file, relative to the current directory; repeatable;
                    default: broadcast/ of the project, the nearest directory up with foundry.toml or sprue.json
  --out <file>      write the page to file, replacing it; without --out the page goes to stdout, which must not
                    be a terminal: redirect it (\`> map.html\`) or name a file
  --title <text>    the page title; default: the project's directory name

Names come from out/ when the project has it. Nothing is sent or changed but the --out file.

  0   the page was written
  1   no transaction in the records, or the page could not be written
  2   usage error, or a refusal: a flag that does not apply, an unknown network, no project and no --records,
      stdout is a terminal and there is no --out
`;

class Refusal extends Error {}
const refuse = (msg) => { throw new Refusal(msg); };
const isDir = (p) => { try { return statSync(p).isDirectory(); } catch { return false; } };

function project(from) {
  for (let d = resolve(from); ; d = dirname(d)) {
    if (existsSync(join(d, 'sprue.json')) || existsSync(join(d, 'foundry.toml'))) return d;
    if (dirname(d) === d) return null;
  }
}

// Returns the exit code.
export function cli(argv, cwd = process.cwd()) {
  const records = [];
  let outFile = null, title = null, network = null;
  try {
    for (let i = 0; i < argv.length; i++) {
      const a = argv[i];
      if (a === '-h' || a === '--help') { process.stdout.write(USAGE); return 0; }
      if (a === '--records' || a === '--out' || a === '--title') {
        const v = argv[++i];
        if (a === '--out' && v === '-') refuse('refusing --out -: without --out the page goes to stdout; name a file, or redirect: sprue map > map.html');
        if (v === undefined || v.startsWith('-')) refuse(`${a} needs a value: ${a} <${a === '--records' ? 'path' : a === '--out' ? 'file' : 'text'}>`);
        if (a === '--records') records.push(v);
        else if (a === '--out') outFile = v;
        else title = v;
      } else if (a.startsWith('-')) refuse(`refusing ${a}: map takes only --records, --out and --title; see sprue map --help`);
      else if (network === null) network = a;
      else refuse(`refusing ${a}: map takes one network, and ${network} is named; name broadcast records with --records`);
    }
    const root = project(cwd);
    if (!root && !records.length) refuse(`no foundry.toml or sprue.json in ${cwd} or above: run inside a Foundry project, or name the records with --records <broadcast dir or file>`);
    let sprue = null;
    if (network !== null) {
      if (!/^[a-z0-9][a-z0-9-]*$/.test(network)) refuse(`refusing network '${network}': not a plain name`);
      const cfg = root && existsSync(join(root, 'sprue.json')) ? JSON.parse(readFileSync(join(root, 'sprue.json'), 'utf8')) : null;
      if (!cfg) refuse(`${network} names sprue's journals, and ${root || cwd} has no sprue.json: drop the network for a map of the broadcast records alone`);
      const dir = join(root, String(cfg.paths?.deployments || 'deployments'));
      if (!existsSync(join(dir, network, 'network.json'))) refuse(`unknown network '${network}': no ${join(dir, network, 'network.json')}`);
      sprue = { dir, network };
    }
    const paths = records.length ? records.map((r) => resolve(cwd, r)) : [join(root, 'broadcast')];
    for (const p of paths) if (!existsSync(p)) refuse(`${p} does not exist: run the deployment with --broadcast first, or name other records with --records`);
    if (outFile === null && process.stdout.isTTY) refuse('refusing to write a page to the terminal: name a file with --out map.html, or redirect: sprue map > map.html');
    const model = build({ paths, project: root, sprue });
    if (!model.txs.length) { process.stderr.write(`sprue: no broadcast records with transactions under ${paths.join(' ')}: broadcast a script, or name other records with --records\n`); return 1; }
    const scripts = [...new Set(model.txs.map((x) => x.script))];
    const more = scripts.length > 1 ? ` +${scripts.length - 1} script${scripts.length > 2 ? 's' : ''}` : '';
    const page = render(model, title || `Deployment map: ${root ? `${basename(root)} (${scripts.length} script${scripts.length > 1 ? 's' : ''})` : scripts[0] + more}`);
    const target = outFile ?? '-';
    const s = model.stats;
    process.stderr.write(`sprue: map of ${root ? `project ${root}` : 'the named records'}${sprue ? `, journals of ${network}` : ''}, records ${paths.join(' ')}, to ${target === '-' ? 'stdout' : target}\n`
      + `sprue: ${s.nodes} nodes, ${s.edges} links (${s.control} control, ${s.controlEvents} of them from events), ${s.steps} steps, ${s.txs} transactions\n`);
    for (const w of model.warnings) process.stderr.write(`sprue: ${w}\n`);
    if (target === '-') process.stdout.write(page);
    else {
      try { writeFileSync(resolve(cwd, target), page); } catch (e) { process.stderr.write(`sprue: cannot write ${target}: ${e.message}; choose another file with --out\n`); return 1; }
    }
    return 0;
  } catch (e) {
    if (!(e instanceof Refusal || e instanceof SyntaxError)) throw e;
    process.stderr.write(`sprue: ${e.message}\n`);
    return 2;
  }
}

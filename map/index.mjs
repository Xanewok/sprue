// SPDX-License-Identifier: MIT
// A static HTML map of a Foundry deployment, from forge's broadcast records. See README.md.
import { existsSync } from 'node:fs';
import { join, basename, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { build } from './model.mjs';
import { render } from './page.mjs';

export { keccak256 } from './abi.mjs';
export { GEOM, place } from './layout.mjs';
export { build, render };

const USAGE = `usage: node map/index.mjs [--project <dir>] [--sprue <project dir> <network>] [--title <text>] <broadcast dir or record files...> > map.html
  --project <dir>   read constructor and function parameter names from <dir>/out
  --sprue <dir> <network>
                    add role names, certificate-verified links and step ids from <dir>/deployments/<network>;
                    implies --project <dir>, and <dir>/broadcast when no records are named`;

function main(argv) {
  const paths = [];
  let project = null, sprue = null, title = null;
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--project') project = argv[++i];
    else if (a === '--sprue') {
      sprue = { dir: argv[++i], network: argv[++i] };
      if (!sprue.dir || !sprue.network) return fail('--sprue needs a project directory and a network name');
    } else if (a === '--title') title = argv[++i];
    else if (a === '-h' || a === '--help') { process.stdout.write(USAGE + '\n'); return 0; }
    else if (a.startsWith('-')) return fail(`unknown option ${a}`);
    else paths.push(a);
  }
  if (sprue) {
    project = project || sprue.dir;
    if (!paths.length) paths.push(join(sprue.dir, 'broadcast'));
  }
  if (!paths.length) return fail('name a broadcast directory or record files');
  for (const p of paths) if (!existsSync(p)) return fail(`${p} does not exist`);
  const model = build({ paths, project, sprue });
  if (!model.txs.length) return fail(`no broadcast records with transactions under ${paths.join(' ')}`);
  const scripts = [...new Set(model.txs.map((x) => x.script))];
  const more = scripts.length > 1 ? ` +${scripts.length - 1} script${scripts.length > 2 ? 's' : ''}` : '';
  process.stdout.write(render(model, title || `Deployment map: ${project ? `${basename(resolve(project))} (${scripts.length} script${scripts.length > 1 ? 's' : ''})` : scripts[0] + more}`));
  const s = model.stats;
  process.stderr.write(`deploy-map: ${s.nodes} nodes, ${s.edges} edges (${s.edgesDecoded} decoded, ${s.control} control, ${s.controlEvents} of them from events), ${s.steps} steps, ${s.txs} transactions\n`);
  for (const w of model.warnings) process.stderr.write(`deploy-map: ${w}\n`);
  return 0;
}

function fail(msg) {
  process.stderr.write(`deploy-map: ${msg}\n${USAGE}\n`);
  return 2;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) process.exitCode = main(process.argv.slice(2));

/**
 * Renders every promo film to marketing/promo/out/.
 *
 * Sequential on purpose: each render already saturates the CPU with parallel
 * Chrome tabs, so running films concurrently only makes them all slower.
 */
import {execFileSync} from 'node:child_process';
import {mkdirSync} from 'node:fs';
import os from 'node:os';

const FILMS = [
  ['PosCheckout', 'daftar-pos-checkout'],
  ['AiAssistant', 'daftar-ai-assistant'],
  ['Inventory', 'daftar-inventory'],
  ['Reports', 'daftar-reports'],
];

const concurrency = Math.max(2, Math.min(8, os.cpus().length - 2));
mkdirSync('out', {recursive: true});

for (const [id, slug] of FILMS) {
  const out = `out/${slug}.mp4`;
  console.log(`\n▶  ${id} → ${out}`);
  const started = Date.now();
  execFileSync(
    'npx',
    ['remotion', 'render', id, out, `--concurrency=${concurrency}`, '--log=error'],
    {stdio: 'inherit'},
  );
  console.log(`✓  ${slug}.mp4 in ${Math.round((Date.now() - started) / 1000)}s`);
}

console.log('\nAll four films rendered to out/.');

/**
 * Renders every poster to marketing/promo/out/posters/ as a 1080×1350 PNG.
 *
 * One still per composition, sequentially — each `remotion still` rebundles, so
 * running them in parallel just fights over the same cores.
 */
import {execFileSync} from 'node:child_process';
import {mkdirSync} from 'node:fs';

const POSTERS = [
  ['PosterBrand', '01-brand'],
  ['PosterCheckout', '02-checkout'],
  ['PosterAi', '03-ai'],
  ['PosterOffline', '04-offline'],
  ['PosterStock', '05-stock'],
  ['PosterReports', '06-reports'],
  ['PosterCredit', '07-credit'],
  ['PosterPriceChecker', '08-price-checker'],
  ['PosterCompare', '09-compare'],
  ['PosterMinutes', '10-minutes'],
  ['PosterAttendance', '11-attendance'],
  ['PosterFx', '12-fx'],
  ['PosterAiInvoice', '13-ai-invoice'],
  ['PosterAiCapabilities', '14-ai-capabilities'],
  ['PosterKiosk', '15-kiosk'],
];

mkdirSync('out/posters', {recursive: true});

for (const [id, slug] of POSTERS) {
  const out = `out/posters/${slug}.png`;
  const started = Date.now();
  execFileSync('npx', ['remotion', 'still', id, out, '--log=error'], {stdio: 'inherit'});
  console.log(`✓  ${slug}.png in ${Math.round((Date.now() - started) / 1000)}s`);
}

console.log(`\n${POSTERS.length} posters rendered to out/posters/.`);

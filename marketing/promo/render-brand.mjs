/**
 * Renders the profile and cover artwork to marketing/promo/out/brand/.
 *
 * These are the files you upload once when setting a page up, so the names are
 * the platform they belong to — not the composition id.
 */
import {execFileSync} from 'node:child_process';
import {mkdirSync} from 'node:fs';

const ASSETS = [
  ['Avatar', 'avatar-1080'],
  ['CoverFacebook', 'cover-facebook-1640x624'],
  ['CoverYouTube', 'cover-youtube-2560x1440'],
  ['HighlightFeatures', 'highlight-features'],
  ['HighlightPricing', 'highlight-pricing'],
  ['HighlightSetup', 'highlight-setup'],
  ['HighlightCustomers', 'highlight-customers'],
  ['HighlightContact', 'highlight-contact'],
];

mkdirSync('out/brand', {recursive: true});

for (const [id, slug] of ASSETS) {
  const out = `out/brand/${slug}.png`;
  const started = Date.now();
  execFileSync('npx', ['remotion', 'still', id, out, '--log=error'], {stdio: 'inherit'});
  console.log(`\u2713  ${slug}.png in ${Math.round((Date.now() - started) / 1000)}s`);
}

console.log(`\n${ASSETS.length} brand assets rendered to out/brand/.`);

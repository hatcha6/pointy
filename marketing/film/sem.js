// Finds Flutter widgets by their accessibility label. Flutter web paints to a
// canvas, but with semantics on it mirrors every labelled widget as a DOM node
// sitting exactly over it, so a label gives a live screen position.

async function enable(page) {
  await page.evaluate(() => document.querySelector('flt-semantics-placeholder')?.click());
  await page.waitForTimeout(800);
}

async function nodes(page) {
  return page.$$eval('flt-semantics', els => els.map(e => {
    const r = e.getBoundingClientRect();
    const own = [...e.childNodes].filter(n => n.nodeType === 3).map(n => n.textContent).join('');
    return {
      role: e.getAttribute('role') || '',
      label: (e.getAttribute('aria-label') || own || '').trim(),
      x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2), w: r.width, h: r.height,
    };
  }).filter(n => n.label && n.w > 0 && n.h > 0
    && n.x >= 0 && n.y >= 0 && n.x <= innerWidth && n.y <= innerHeight));
}

/**
 * The centre of the first visible widget whose label matches. A string matches
 * exactly, else as the first line, else as a substring; `nth` picks among
 * several. Waits for it to appear, since sheets and results animate in.
 */
async function find(page, label, nth = 0, timeout = 8000) {
  const end = Date.now() + timeout;
  for (;;) {
    const all = await nodes(page);
    for (const test of [
      n => n.label === label,
      n => n.label.split('\n')[0].trim() === label,
      n => n.label.includes(label),
    ]) {
      const hits = all.filter(test);
      if (hits[nth]) return hits[nth];
    }
    if (Date.now() > end) throw new Error(`no widget labelled «${label}»`);
    await page.waitForTimeout(150);
  }
}

module.exports = {enable, nodes, find};

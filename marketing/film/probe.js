// Explores a harness state at the capture viewport through Flutter's semantics tree.
//   node probe.js <harness> '<query>' '[["tap","label"],["xy",x,y],["type","text"],["key","Enter"],
//                                      ["wait",ms],["shot","name"],["dump"]]'
process.env.CAPTURE_WORK ||= `${__dirname}/.work`;
process.env.OUT ||= `${__dirname}/.work/probe`;
const L = require('../website/capture/lib');
const S = require('./sem');

(async () => {
  const [h, query, steps = '[]'] = process.argv.slice(2);
  const {page, ctx} = await L.open(h, query, {w: 1440, h: 900, dpr: 1});
  await S.enable(page);
  for (const [op, a, b] of JSON.parse(steps)) {
    if (op === 'tap') { const p = await S.find(page, a, b); await page.mouse.click(p.x, p.y); }
    if (op === 'xy') await page.mouse.click(a, b);
    if (op === 'type') await page.keyboard.type(a, {delay: 40});
    if (op === 'key') await page.keyboard.press(a);
    if (op === 'wait') await page.waitForTimeout(a);
    if (op === 'shot') await L.shot(page, a);
    if (op === 'dump') (await S.nodes(page)).forEach(n => console.log(`${n.role || '-'} | ${n.label.replace(/\n/g, ' / ')} | ${n.x},${n.y}`));
    if (op === 'tap' || op === 'xy' || op === 'key') await page.waitForTimeout(700);
  }
  await ctx.close();
  await L.done();
})();

// Records the POS tour's scenes from the real harnesses, desktop size.
//   node capture.js [scene ...]          (default: all)
// Each scene writes .work/captures/<id>.mp4 (2880x1800) and <id>.json: every tap
// and focus point with its time, which the vertical cut's camera follows.
process.env.CAPTURE_WORK ||= `${__dirname}/.work`;
process.env.OUT ||= `${__dirname}/.work/captures`;
const fs = require('fs');
const L = require('../website/capture/lib');
const S = require('./sem');
const fsrv = require('../website/capture/footage-server');
const slipUrl = require('./slip');

const POS = '?screen=pos&banks=on&links=on&printer=on&rail=collapsed';
const VOUCHERS = '?screen=menu&seed=off&printer=on&menu=live';

/** A page plus the helpers a scene drives it with. */
async function stage(harness, query, size = {w: 1440, h: 900}) {
  const {page, ctx} = await L.open(harness, query, {...size, dpr: 2});
  await S.enable(page);
  let t0 = null;
  const marks = [];
  const mark = (kind, x, y, extra = {}) => {
    if (t0 !== null) marks.push({t: (Date.now() - t0) / 1000, kind, x, y, ...extra});
  };
  const wait = ms => page.waitForTimeout(ms);
  const s = {
    page, wait,
    /** Glide to the widget labelled `label`, press it, log it. */
    async tap(label, {nth = 0, after = 650, dx = 0, dy = 0} = {}) {
      const p = typeof label === 'string' ? await S.find(page, label, nth) : label;
      const x = p.x + dx, y = p.y + dy;
      await page.mouse.move(x, y, {steps: 22});
      await wait(110);
      mark('tap', x, y, {label: typeof label === 'string' ? label : ''});
      await page.mouse.down(); await wait(90); await page.mouse.up();
      await wait(after);
    },
    /** Point the camera somewhere without touching it. */
    focus(x, y, zoom) { mark('focus', x, y, {zoom}); },
    async focusOn(label, zoom) { const p = await S.find(page, label); mark('focus', p.x, p.y, {zoom}); },
    /** Typing as a person does it. */
    type: (text, delay = 85) => L.type(page, text, delay),
    /** A scanner: a burst of keystrokes and Enter. */
    async scan(code) { await page.keyboard.type(code, {delay: 8}); await page.keyboard.press('Enter'); },
    async record(id, fn) {
      await page.evaluate(() => { window.__touches = true; });
      await L.record(page, id, async () => { t0 = Date.now(); await fn(); });
      const {width, height} = page.viewportSize();
      fs.writeFileSync(`${process.env.OUT}/${id}.json`, JSON.stringify({id, width, height, marks}, null, 1));
      await ctx.close();
    },
  };
  return s;
}

const clearCart = async s => { await s.tap('مسح السلة', {after: 400}); await s.tap('مسح', {after: 500}); };
const pickCustomer = async (s, name) => {
  await s.tap('إعدادات الفاتورة'); await s.tap('تغيير', {after: 900});
  await s.tap(name); await s.tap('حفظ');
};

const scenes = {
  async hook() {
    const s = await stage('pos_preview', POS);
    await s.page.mouse.move(1100, 500);
    await s.record('hook', async () => {
      s.focus(720, 450, 1);
      await s.page.mouse.move(900, 420, {steps: 60}); await s.wait(1500);
      await s.page.mouse.move(300, 600, {steps: 60}); await s.wait(2500);
    });
  },

  async search() {
    const s = await stage('pos_preview', POS);
    await clearCart(s);
    await s.record('search', async () => {
      await s.wait(400);
      await s.tap({x: 1000, y: 160}, {after: 200});
      await s.type('قهوة');
      await s.wait(600);
      await s.tap('قهوة عربية مختصة', {after: 900});
      await s.tap({x: 699, y: 160}, {after: 300});
      s.focus(1000, 160, 2.2);
      await s.scan('1000006');
      await s.wait(500);
      await s.focusOn('كرواسون', 1.8);
      await s.wait(1400);
    });
  },

  async units() {
    const s = await stage('pos_preview', POS);
    await clearCart(s);
    await s.record('units', async () => {
      await s.wait(300);
      await s.tap('مشروبات');
      await s.tap('ماء معدني', {after: 800});
      await s.tap('عبوة', {after: 900});
      await s.tap('كرتون ·', {after: 600});
      await s.tap('إضافة ·', {after: 700});
      await s.focusOn('كرتون', 2);
      await s.wait(1200);
    });
  },

  async held() {
    const s = await stage('pos_preview', POS);
    await s.record('held', async () => {
      await s.wait(300);
      await s.tap('إدارة الفواتير المفتوحة', {after: 800});
      await s.tap('فاتورة جديدة', {after: 800});
      await s.tap('لاتيه بالكراميل', {after: 700});
      await s.tap('إدارة الفواتير المفتوحة', {after: 1000});
      await s.tap('فاتورة 1', {after: 900});
      await s.wait(600);
    });
  },

  async discount() {
    const s = await stage('pos_preview', POS);
    await s.record('discount', async () => {
      s.focus(230, 720, 2.2); // the rule and coupon rows
      await s.wait(1300);
      await s.tap('إضافة خصم', {after: 700});
      await s.type('1.20', 140);
      await s.wait(300);
      await s.tap('حفظ', {after: 600});
      s.focus(230, 760, 2.2); // the totals
      await s.wait(1500);
    });
  },

  async methods() {
    const s = await stage('pos_preview', POS);
    await s.record('methods', async () => {
      await s.wait(300);
      await s.tap('ادفع', {after: 1300});
      await s.tap('بطاقة', {after: 1500});
      await s.tap('تحويل', {after: 1500});
      await s.tap('نقد', {after: 1100});
      await s.focusOn('تأكيد الدفع', 2);
      await s.page.mouse.move(320, 757, {steps: 30});
      await s.wait(1600);
    });
  },

  async split() {
    const s = await stage('pos_preview', POS);
    await s.tap('ادفع', {after: 1000});
    await s.record('split', async () => {
      await s.wait(300);
      await s.tap('إضافة دفعة', {after: 800});
      await s.tap({x: 864, y: 407}, {after: 200});
      await s.page.keyboard.press('Meta+a');
      await s.type('20', 160);
      await s.tap({x: 864, y: 568}, {after: 200});
      await s.type('26.20', 140);
      s.focus(330, 330, 1.8); // due / paid / remaining
      await s.wait(1300);
    });
  },

  async bank() {
    const s = await stage('pos_preview', POS);
    await s.tap('ادفع', {after: 1000});
    await s.tap('بطاقة', {after: 700});
    await s.record('bank', async () => {
      await s.wait(300);
      await s.tap('الحساب البنكي', {after: 900});
      await s.tap('حساب الأمان', {after: 900});
      await s.focusOn('الحساب البنكي', 2.2);
      await s.wait(1000);
    });
  },

  async slip() {
    const s = await stage('pos_preview', POS);
    await s.tap('ادفع', {after: 1000});
    await s.tap('إضافة دفعة', {after: 700});
    await s.tap({x: 864, y: 407}, {after: 200});
    await s.page.keyboard.press('Meta+a');
    await s.page.keyboard.type('20');
    await s.tap({x: 864, y: 568}, {after: 200});
    await s.page.keyboard.type('26.20');
    await s.wait(400);
    await s.record('slip', async () => {
      s.focus(1008, 600, 1.7);
      await s.wait(1400);
      s.focus(1008, 650, 2.1, ); // the scan lands here
      await s.scan(slipUrl(26.20));
      await s.wait(700);
      await s.focusOn('تمت المطابقة', 2.3);
      await s.wait(2600);
    });
  },

  async done() {
    const s = await stage('pos_preview', POS);
    await s.tap('ادفع', {after: 1000});
    await s.record('done', async () => {
      await s.wait(300);
      await s.tap('50.00 د.ل', {after: 700});
      await s.tap('تأكيد الدفع', {after: 2600});
      s.focus(720, 345, 2); // the change
      await s.wait(1200);
      await s.focusOn('فاتورة الزبون على الإنترنت', 2.2);
      await s.wait(1800);
    });
  },

  async credit() {
    const s = await stage('pos_preview', POS);
    await pickCustomer(s, 'مطعم الريحان');
    await s.record('credit', async () => {
      await s.wait(200);
      await s.tap('ادفع', {after: 900});
      await s.tap('آجل', {after: 800});
      await s.tap('بعد شهر', {after: 600});
      await s.tap('إضافة دفعة مقدّمة', {after: 600});
      await s.tap({x: 864, y: 501}, {after: 150});
      await s.page.keyboard.press('Meta+a');
      await s.type('10', 160);
      await s.tap('تأكيد الدفع', {after: 2400});
      s.focus(720, 345, 2); // what the customer owes
      await s.wait(1500);
    });
  },

  async quote() {
    const s = await stage('pos_preview', POS);
    await pickCustomer(s, 'محمد الورفلي');
    await s.record('quote', async () => {
      await s.wait(200);
      await s.tap('ادفع', {after: 900});
      await s.tap('عرض سعر', {after: 800});
      await s.tap('حجز الكمية', {after: 700});
      await s.focusOn('صالح حتى', 2);
      await s.wait(900);
      await s.tap('تأكيد', {after: 2400});
      await s.wait(1000);
    });
  },

  async vouchers() {
    const s = await stage('voucher_menu_preview', VOUCHERS);
    await s.page.mouse.move(900, 600);
    await s.record('vouchers', async () => {
      await s.wait(600);
      await L.smoothScroll(s.page, 700, 30, 830, 600); await s.wait(500);
      await L.smoothScroll(s.page, -700, 20, 830, 600); await s.wait(300);
      await s.tap('ليبيانا', {after: 1100});
      await s.tap('10 دينار', {after: 900});
      await s.tap('ادفع', {after: 900});
      await s.tap('تأكيد الدفع', {after: 2600});
      s.focus(720, 460, 2); // the PIN card
      await s.wait(2200);
    });
  },

  // The till side of the counter camera: a read lands in the cart like a scan.
  async wedge() {
    const s = await stage('pos_preview', POS);
    await clearCart(s);
    await s.tap({x: 1000, y: 160}, {after: 300});
    await s.record('wedge', async () => {
      await s.wait(1600);
      await s.scan('1000001');
      await s.wait(900);
      await s.scan('1000006');
      await s.wait(2600);
    });
  },

  // The F8 panel itself, painting its live frames; floated over the till in the cut.
  async 'wedge-panel'() {
    const s = await stage('camera_wedge_preview', '?screen=panel');
    await s.record('wedge-panel', async () => { await s.wait(6000); });
  },

  // What the customer's phone opens from the receipt's QR: the relay's own page,
  // rendered from the same sale by invoice/render.sh (run it first).
  async online() {
    const {chromium} = require('../website/capture/node_modules/playwright');
    const browser = await chromium.launch({headless: true, channel: 'chromium'});
    const ctx = await browser.newContext({viewport: {width: 390, height: 844}, deviceScaleFactor: 3, isMobile: true, hasTouch: true, locale: 'ar'});
    const page = await ctx.newPage();
    await page.goto(`file://${__dirname}/.work/public-invoice.html`);
    await page.waitForTimeout(800);
    await L.record(page, 'online', async () => {
      await page.waitForTimeout(1600);
      await L.smoothScroll(page, 420, 60, 195, 500); await page.waitForTimeout(1400);
      await L.smoothScroll(page, 600, 60, 195, 500); await page.waitForTimeout(1600);
    });
    fs.writeFileSync(`${process.env.OUT}/online.json`, JSON.stringify({id: 'online', width: 390, height: 844, marks: []}));
    await browser.close();
  },

  async cctv() {
    const rig = await fsrv();
    const s = await stage('cameras_preview', `?screen=invoice&source=rig-clean&rig=${encodeURIComponent(rig)}`, {w: 900, h: 900});
    await s.record('cctv', async () => {
      await s.wait(500);
      await s.tap('تشغيل اللقطة', {after: 5000});
    });
  },
};

(async () => {
  const only = process.argv.slice(2);
  for (const [id, run] of Object.entries(scenes)) {
    if (only.length && !only.includes(id)) continue;
    try { await run(); } catch (e) { console.log('ERR', id, e.message.slice(0, 200)); }
  }
  await L.done();
})();

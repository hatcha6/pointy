// دفتر product page — progressive enhancement only. Without this file every
// section still renders: images show, videos show their posters.
(() => {
  const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const clamp = (v, a = 0, b = 1) => Math.min(b, Math.max(a, v));

  // ---- reveal on enter ----
  const revealIO = new IntersectionObserver((entries) => {
    for (const e of entries) if (e.isIntersecting) { e.target.classList.add('in'); revealIO.unobserve(e.target); }
  }, { rootMargin: '0px 0px -12% 0px' });
  $$('[data-reveal]').forEach((el) => revealIO.observe(el));

  // ---- videos: fetched only near the viewport, played only while visible ----
  const load = (v) => { if (!v.src && v.dataset.src) { v.src = v.dataset.src; } };
  const videoIO = new IntersectionObserver((entries) => {
    for (const e of entries) {
      const v = e.target;
      if (v.closest('[data-carousel]')) continue; // the carousel drives its own
      if (e.isIntersecting) { load(v); if (!reduce && !v.dataset.userPaused) v.play().catch(() => {}); }
      else if (!v.paused) v.pause();
    }
  }, { threshold: 0.35 });
  $$('video[data-src]').forEach((v) => {
    videoIO.observe(v);
    if (reduce) v.controls = true;
  });

  // ---- scroll-linked progress (--p) for sticky stages ----
  const scrubs = $$('[data-scrub]');
  const words = [];
  $$('[data-words]').forEach((p) => {
    const walk = (node, accent) => {
      for (const n of [...node.childNodes]) {
        if (n.nodeType === 3) {
          const frag = document.createDocumentFragment();
          n.textContent.split(/(\s+)/).forEach((t) => {
            if (!t.trim()) { frag.append(t); return; }
            const s = document.createElement('span'); s.className = 'w' + (accent ? ' t' : ''); s.textContent = t; frag.append(s); words.push(s);
          });
          n.replaceWith(frag);
        } else if (n.nodeType === 1) {
          walk(n, accent || n.classList.contains('t'));
        }
      }
    };
    walk(p, false);
  });

  const upd = document.querySelector('[data-upd]');
  const steps = $$('[data-steps] li');
  const sales = $$('[data-sales]');
  const salesBase = sales.map((s) => +s.textContent);

  function progressOf(el) {
    const r = el.getBoundingClientRect();
    const run = r.height - innerHeight;
    return run > 0 ? clamp(-r.top / run) : clamp((innerHeight - r.top) / (innerHeight + r.height));
  }

  function frame() {
    for (const el of scrubs) {
      const p = progressOf(el);
      if (el.classList.contains('hero-stage')) {
        if (innerWidth <= 760) continue; // phones: hero renders flat, no sticky stage
        const d = el.querySelector('.hero-device');
        const hp = clamp(p * 2.2);
        d.style.setProperty('--p', hp.toFixed(4));
        el.querySelector('.hero-glow').style.setProperty('--p', hp.toFixed(4));
        el.querySelector('.hero-caption').style.setProperty('--p', clamp(p * 2.2 - 0.6).toFixed(4));
      } else if (el.classList.contains('statement')) {
        const lit = Math.round(clamp(p * 1.35 - 0.12) * words.length);
        words.forEach((w, i) => w.classList.toggle('on', i < lit));
      } else if (el.id === 'updates' && upd) {
        updateTimeline(clamp(p * 1.2 - 0.05));
      }
    }
  }

  function updateTimeline(p) {
    const stage = p < 0.3 ? 0 : p < 0.55 ? 1 : p < 0.75 ? 2 : 3;
    steps.forEach((li, i) => li.classList.toggle('on', i <= stage));
    const oldS = upd.querySelector('[data-srv="old"]');
    const newS = upd.querySelector('[data-srv="new"]');
    oldS.classList.toggle('live', stage < 2); oldS.classList.toggle('gone', stage === 3);
    newS.classList.toggle('prep', stage === 0 || stage === 1); newS.classList.toggle('live', stage >= 2);
    upd.querySelector('[data-old-state]').textContent = ['يخدم الكاشير', 'يخدم الكاشير', 'ينهي آخر طلب', 'متوقف'][stage];
    upd.querySelector('[data-new-state]').textContent = ['يتنزّل…', 'يفحص الجاهزية', 'يخدم الكاشير', 'يخدم الكاشير'][stage];
    upd.querySelector('.prog').style.setProperty('--p', clamp(p / 0.3).toFixed(3));
    // the tills never stop ringing sales through the whole switch
    sales.forEach((s, i) => { s.textContent = salesBase[i] + Math.floor(p * (18 - i * 5)); });
  }

  if (!reduce && scrubs.length) {
    let ticking = false;
    const onScroll = () => { if (!ticking) { ticking = true; requestAnimationFrame(() => { frame(); ticking = false; }); } };
    addEventListener('scroll', onScroll, { passive: true });
    addEventListener('resize', onScroll);
    frame();
  } else {
    words.forEach((w) => w.classList.add('on'));
    if (upd) updateTimeline(1);
  }

  // ---- counters ----
  const fmt = (n, dec) => dec ? n.toFixed(dec) : Math.round(n).toLocaleString('en-US');
  const countIO = new IntersectionObserver((entries) => {
    for (const e of entries) {
      if (!e.isIntersecting) continue;
      const el = e.target; countIO.unobserve(el);
      const to = +el.dataset.count, dec = +(el.dataset.dec || 0);
      if (reduce) { el.textContent = fmt(to, dec); continue; }
      const t0 = performance.now(), dur = 1400;
      const tick = (t) => { const k = clamp((t - t0) / dur); const ease = 1 - Math.pow(1 - k, 3); el.textContent = fmt(to * ease, dec); if (k < 1) requestAnimationFrame(tick); };
      requestAnimationFrame(tick);
    }
  }, { threshold: 0.6 });
  $$('[data-count]').forEach((el) => countIO.observe(el));

  // ---- latency bars (scaled to the slowest p95 shown) ----
  $$('[data-bars]').forEach((box) => {
    const max = Math.max(...$$('[data-w]', box).map((i) => +i.dataset.w));
    const io = new IntersectionObserver(([e]) => {
      if (!e.isIntersecting) return; io.disconnect(); box.classList.add('in');
      $$('[data-w]', box).forEach((i) => { i.style.width = (100 * i.dataset.w / max) + '%'; });
    }, { threshold: 0.4 });
    io.observe(box);
  });

  // ---- highlights carousel ----
  $$('[data-carousel]').forEach((track) => {
    const cards = $$('.hl-card', track);
    const dots = track.parentElement.querySelector('.dots');
    const toggle = track.parentElement.querySelector('[data-hl-toggle]');
    let current = 0, paused = reduce, timer = 0, visible = false;
    cards.forEach((c, i) => {
      const b = document.createElement('button');
      b.type = 'button'; b.setAttribute('role', 'tab'); b.setAttribute('aria-label', String(i + 1));
      b.addEventListener('click', () => { go(i, true); });
      dots.append(b);
    });
    const dotEls = $$('button', dots);
    const pauseIcon = toggle.innerHTML;
    const playIcon = '<svg viewBox="0 0 16 16" fill="currentColor"><path d="M4 2.5v11a.5.5 0 0 0 .77.42l8.5-5.5a.5.5 0 0 0 0-.84l-8.5-5.5A.5.5 0 0 0 4 2.5z"/></svg>';
    const setToggle = () => { toggle.innerHTML = paused ? playIcon : pauseIcon; toggle.setAttribute('aria-label', paused ? 'تشغيل' : 'إيقاف مؤقت'); };
    setToggle();

    function scrollToCard(i) {
      const c = cards[i];
      const pad = parseFloat(getComputedStyle(track).scrollPaddingInlineStart) || 0;
      // RTL: card offsets are measured from the right edge
      const delta = (track.getBoundingClientRect().right - pad) - c.getBoundingClientRect().right;
      track.scrollBy({ left: -delta, behavior: reduce ? 'auto' : 'smooth' });
    }
    function activate(i) {
      current = i;
      dotEls.forEach((d, k) => d.setAttribute('aria-current', String(k === i)));
      clearTimeout(timer);
      cards.forEach((c, k) => { const v = c.querySelector('video'); if (v && k !== i) v.pause(); });
      const v = cards[i].querySelector('video');
      if (!visible) return;
      if (v) {
        load(v); v.loop = false;
        if (!paused) { v.currentTime = 0; v.play().catch(() => {}); }
        v.onended = () => { if (!paused) go((i + 1) % cards.length); };
      } else if (!paused) {
        timer = setTimeout(() => go((i + 1) % cards.length), 5000);
      }
    }
    function go(i, user) { if (user) { paused = false; setToggle(); } scrollToCard(i); activate(i); }

    // keep the dot in step with manual swipes
    let st = 0;
    track.addEventListener('scroll', () => {
      clearTimeout(st);
      st = setTimeout(() => {
        const mid = track.getBoundingClientRect().right - (parseFloat(getComputedStyle(track).scrollPaddingInlineStart) || 0);
        let best = 0, bd = Infinity;
        cards.forEach((c, k) => { const d = Math.abs(c.getBoundingClientRect().right - mid); if (d < bd) { bd = d; best = k; } });
        if (best !== current) activate(best);
      }, 120);
    }, { passive: true });

    toggle.addEventListener('click', () => {
      paused = !paused; setToggle();
      const v = cards[current].querySelector('video');
      if (paused) { clearTimeout(timer); if (v) v.pause(); } else activate(current);
    });

    new IntersectionObserver(([e]) => {
      visible = e.isIntersecting;
      if (visible) activate(current);
      else { clearTimeout(timer); cards.forEach((c) => c.querySelector('video')?.pause()); }
    }, { threshold: 0.4 }).observe(track);
    activate(0);
  });

  // ---- light / dark compare ----
  $$('[data-compare]').forEach((box) => {
    const input = box.querySelector('input');
    const set = () => box.style.setProperty('--x', input.value + '%');
    input.addEventListener('input', set); set();
  });

  // ---- placeholder contact links: say so instead of jumping to the top ----
  $$('[data-todo]').forEach((a) => a.addEventListener('click', (e) => e.preventDefault()));
})();

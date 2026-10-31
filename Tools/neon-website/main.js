(() => {
  'use strict';

  const REPO = 'Dryxio/san-andreas-online';
  const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  /* ---------- Language ----------
     English lives at / and French at /fr/. Both are full static pages (build.py
     writes the French one) so search engines index each language on its own
     URL. A French browser landing on / for the first time is sent to /fr/;
     the EN/FR link remembers an explicit choice so nobody gets bounced back. */
  const LANG = document.documentElement.lang === 'fr' ? 'fr' : 'en';
  const store = {
    get(k) { try { return localStorage.getItem(k); } catch { return null; } },
    set(k, v) { try { localStorage.setItem(k, v); } catch { /* private mode */ } },
  };
  const switcher = document.getElementById('lang');
  switcher.addEventListener('click', () => store.set('neon-lang', switcher.dataset.langSwitch));
  const wanted = store.get('neon-lang');
  if (LANG === 'en' && (wanted === 'fr' || (!wanted && (navigator.language || '').toLowerCase().startsWith('fr')))) {
    location.replace(`/fr/${location.hash}`);
  }

  // Text the scripts below set at runtime; the rest of the page is already in the right language.
  const TEXT = {
    en: {
      'cmp.c1': 'In the original, the far side of town is a mess of low-detail boxes. Here the real buildings load all the way to the hills.',
      'cmp.c2': 'At night the whole skyline stays lit, not only the few blocks around you.',
      'cmp.c3': 'Warmer colours, closer to how the game looked on a PS2.',
      'alt.draw-distance': ['Original game: distant buildings are low-detail boxes', 'San Andreas Online: distant buildings stay detailed'],
      'alt.project2dfx': ['Original game at night: the skyline fades into fog', 'San Andreas Online at night: hundreds of distant city lights'],
      'alt.skygfx': ['Original game: a street in Ganton with neutral colours', 'San Andreas Online: a street in Ganton with warm PS2-style colours'],
      'meta.free': 'Free',
      'meta.mb': 'MB',
      locale: 'en-GB',
    },
    fr: {
      'cmp.c1': 'Dans l’original, le bout de la ville n’est qu’un tas de blocs low-poly. Ici, les vrais bâtiments s’affichent jusqu’aux collines.',
      'cmp.c2': 'La nuit, toute la ville reste éclairée, pas seulement les quelques rues autour de toi.',
      'cmp.c3': 'Des couleurs plus chaudes, plus proches du jeu sur PS2.',
      'alt.draw-distance': ['Jeu original : les bâtiments au loin sont des blocs en basse qualité', 'San Andreas Online : les bâtiments au loin restent détaillés'],
      'alt.project2dfx': ['Jeu original de nuit : la ville disparaît dans le brouillard', 'San Andreas Online de nuit : des centaines de lumières au loin'],
      'alt.skygfx': ['Jeu original : une rue de Ganton aux couleurs neutres', 'San Andreas Online : une rue de Ganton aux couleurs chaudes façon PS2'],
      'meta.free': 'Gratuit',
      'meta.mb': 'Mo',
      locale: 'fr-FR',
    },
  };
  const t = (key) => TEXT[LANG][key] ?? TEXT.en[key] ?? key;

  /* ---------- Live release info ----------
     The button always points at /download (a redirect to the latest installer),
     so this only refreshes the version/size label. Static fallback otherwise. */
  let release = { version: '2026.10.09', mb: 159 };
  function renderMeta() {
    const text = `${t('meta.free')} · v${release.version} · ${release.mb} ${t('meta.mb')}`;
    document.querySelectorAll('#release-meta, .js-meta').forEach((el) => { el.textContent = text; });
  }
  fetch(`https://api.github.com/repos/${REPO}/releases/latest`, { headers: { Accept: 'application/vnd.github+json' } })
    .then((r) => (r.ok ? r.json() : Promise.reject(r.status)))
    .then((data) => {
      const asset = (data.assets || []).find((a) => a.name === 'MTA-Neon-Setup.exe');
      const version = String(data.tag_name || '').replace(/^neon-/, '').split('.').slice(0, 3).join('.');
      if (version) release.version = version;
      if (asset) release.mb = Math.round(asset.size / 1048576);
      renderMeta();
      const latest = document.getElementById('latest-date');
      if (latest && data.published_at) {
        latest.textContent = new Date(data.published_at).toLocaleDateString(t('locale'), { day: 'numeric', month: 'short', year: 'numeric' });
      }
    })
    .catch(() => {});

  /* ---------- Hero slideshow ----------
     Cycles the SA loading-screen art; the loading bar fills over each slide,
     exactly like waiting on a real SA load. */
  const hero = document.getElementById('hero');
  const slides = [...hero.querySelectorAll('.hero__art .slide')];
  const imgOf = (slide) => slide.querySelector('img');
  const fill = document.getElementById('loadbar-fill');
  const SLIDE_MS = 6500;
  let current = 0;
  let started = performance.now();

  function show(i) {
    slides[current].classList.remove('is-active');
    current = (i + slides.length) % slides.length;
    const slide = slides[current];
    if (imgOf(slide).loading === 'lazy') imgOf(slide).loading = 'eager';
    slide.classList.add('is-active');
    // On phones the slide background is off, so the hero itself carries the colour.
    hero.style.setProperty('--top', slide.dataset.top);
    hero.style.setProperty('--bot', slide.dataset.bot);
    // Warm the next image so the crossfade never shows a blank frame.
    const next = imgOf(slides[(current + 1) % slides.length]);
    if (next.loading === 'lazy') next.loading = 'eager';
  }

  function tick(now) {
    const p = Math.min((now - started) / SLIDE_MS, 1);
    fill.style.width = `${(p * 100).toFixed(2)}%`;
    if (p >= 1) { started = now; show(current + 1); }
    requestAnimationFrame(tick);
  }
  if (!reduceMotion) {
    show(0);
    requestAnimationFrame(tick);
    document.addEventListener('visibilitychange', () => { if (!document.hidden) started = performance.now(); });
  } else {
    fill.style.width = '100%';
  }

  /* ---------- Before / after ---------- */
  const box = document.getElementById('compare-box');
  const range = box.querySelector('.compare__range');
  const imgA = document.getElementById('cmp-a');
  const imgB = document.getElementById('cmp-b');
  const caption = document.getElementById('cmp-caption');
  const tabs = [...document.querySelectorAll('.tab')];
  const CMP = {
    'draw-distance': 'cmp.c1',
    project2dfx: 'cmp.c2',
    skygfx: 'cmp.c3',
  };
  let cmpKey = 'draw-distance';

  function setCaption() {
    caption.innerHTML = t(CMP[cmpKey]);
  }
  range.addEventListener('input', () => box.style.setProperty('--pos', `${range.value}%`));
  tabs.forEach((tab) => tab.addEventListener('click', () => {
    cmpKey = tab.dataset.cmp;
    tabs.forEach((b) => { const on = b === tab; b.classList.toggle('is-active', on); b.setAttribute('aria-selected', String(on)); });
    imgA.src = `/assets/img/cmp-${cmpKey}-a.webp`;
    imgB.src = `/assets/img/cmp-${cmpKey}-b.webp`;
    [imgA.alt, imgB.alt] = t(`alt.${cmpKey}`);
    setCaption();
  }));
  // Preload the other comparisons once the section is close.
  new IntersectionObserver((entries, obs) => {
    if (!entries[0].isIntersecting) return;
    Object.keys(CMP).forEach((k) => { ['a', 'b'].forEach((s) => { new Image().src = `/assets/img/cmp-${k}-${s}.webp`; }); });
    obs.disconnect();
  }, { rootMargin: '600px' }).observe(box);

  /* ---------- Mission passed ----------
     The link itself starts the download; this is only the celebration on top. */
  const passed = document.getElementById('passed');
  let passedTimer;
  document.querySelectorAll('.js-download').forEach((a) => a.addEventListener('click', () => {
    clearTimeout(passedTimer);
    passed.hidden = true;
    void passed.offsetWidth; // restart the animation on repeat clicks
    passed.hidden = false;
    passedTimer = setTimeout(() => { passed.hidden = true; }, 2900);
  }));

  renderMeta();
})();

(() => {
  'use strict';

  const REPO = 'Dryxio/san-andreas-online';
  const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  /* ---------- Language ----------
     English lives in the HTML so the page works without JS; French replaces it.
     French is picked automatically for French browsers because much of the
     community asking for this site is French-speaking. */
  const FR = {
    'nav.graphics': 'Graphismes',
    'nav.features': 'Nouveautés',
    'nav.install': 'Installer',
    'nav.creators': 'Créateurs',
    'nav.download': 'Télécharger',
    'hero.cta': 'Télécharger pour Windows',
    'hero.how': 'Comment l’installer',
    'cmp.kicker': 'Intégré. Rien à installer.',
    'cmp.title': 'San Andreas, enfin bien vu',
    'cmp.sub': 'Chaque amélioration s’active dans les paramètres. Fais glisser le curseur pour comparer avec MTA:SA classique.',
    'cmp.t1': 'Distance d’affichage',
    'cmp.t2': 'Lumières de nuit',
    'cmp.t3': 'Couleurs PS2',
    'cmp.c1': 'Les bâtiments au loin restent détaillés au lieu de fondre en blocs low-poly.',
    'cmp.c2': 'Des centaines de lumières au loin : la ville entière s’allume la nuit.',
    'cmp.c3': 'Un étalonnage plus chaud et saturé, comme sur PlayStation 2.',
    'feat.kicker': 'Respect +',
    'feat.title': 'Ce que tu gagnes',
    'feat.1t': 'La vie du mode solo, en ligne',
    'feat.1d': 'Les piétons et le trafic de GTA tournent dans un monde multijoueur partagé. Les rues sont enfin vivantes.',
    'feat.2t': 'Graphismes améliorés, intégrés',
    'feat.2d': 'Grande distance d’affichage, lumières lointaines et couleurs PS2. Pas d’ASI loader, pas de modloader, aucun fichier à copier.',
    'feat.3t': 'Un menu qui sent San Andreas',
    'feat.3d': 'Nouveau menu principal et navigateur de serveurs dans le style du jeu, avec identité Discord en option.',
    'feat.4t': 'Toujours à jour',
    'feat.4d': 'San Andreas Online se met à jour tout seul. Chaque mise à jour est vérifiée par un manifeste signé avant installation.',
    'feat.5t': 'Garde ton MTA:SA',
    'feat.5d': 'San Andreas Online s’installe dans son propre dossier. Ton installation MTA:SA reste intacte.',
    'inst.kicker': 'Nouvelle mission',
    'inst.title': 'Dans la rue en 3 étapes',
    'inst.1t': 'Avoir GTA: San Andreas',
    'inst.1d': 'Ta propre copie du jeu PC original. La Definitive Edition n’est pas compatible.',
    'inst.2t': 'Télécharger San Andreas Online',
    'inst.2d': 'Un seul fichier : <b>MTA-Neon-Setup.exe</b>. C’est tout ce dont un joueur a besoin.',
    'inst.2b': 'Télécharger l’installateur',
    'inst.3t': 'Installer et jouer',
    'inst.3d': 'Lance-le, indique ton dossier GTA: San Andreas, ouvre San Andreas Online et choisis un serveur.',
    'safe.t': 'Windows affiche « Windows a protégé votre ordinateur » ?',
    'safe.d': 'L’installateur est récent et pas encore signé, donc SmartScreen peut afficher un avertissement. Clique sur <b>Informations complémentaires</b>, puis <b>Exécuter quand même</b>. Chaque version est compilée automatiquement depuis le code source public, avec ses sommes SHA-256 publiées.',
    'safe.l': 'Voir les sommes de contrôle →',
    'cr.kicker': 'Pour les créateurs de serveurs',
    'cr.title': 'Le moteur, grand ouvert',
    'cr.sub': 'Des systèmes de GTA verrouillés dans le moteur, devenus des primitives Lua. Chaque image est une vraie capture en jeu.',
    'cr.1t': 'Zones CULL natives',
    'cr.1d': 'Modifie le culling de GTA en Lua',
    'cr.2t': 'Objets du monde',
    'cr.2d': 'Suis, déplace et casse les props de SA',
    'cr.3t': 'Collisions à la volée',
    'cr.3d': 'Crée des collisions sans fichier .col',
    'cr.4t': 'Maps SA-MP',
    'cr.4d': 'Charge directement les exports Pawn',
    'cr.5t': 'Feu géré',
    'cr.5d': 'Des feux synchronisés qui suivent une cible',
    'cr.6t': 'Végétation',
    'cr.6d': 'Fais pousser la végétation de GTA partout',
    'cr.7t': 'Oiseaux scriptables',
    'cr.7d': 'Des nuées pilotables, au-delà des limites',
    'cr.8t': '2DFX des modèles',
    'cr.8d': 'Contrôle les lumières intégrées aux modèles',
    'cr.docs': 'Lire la doc et l’API Lua',
    'cr.server': 'Télécharger un serveur (Windows / Linux)',
    'faq.kicker': 'Avant que tu demandes',
    'faq.1q': 'C’est gratuit ?',
    'faq.1a': 'Oui. San Andreas Online est gratuit et open source sous licence GPL-3.0, comme Multi Theft Auto.',
    'faq.2q': 'Il me faut GTA: San Andreas ?',
    'faq.2a': 'Oui. San Andreas Online n’inclut pas le jeu. Il te faut ta propre copie de la version PC originale. La Definitive Edition ne fonctionne pas.',
    'faq.3q': 'Ça remplace mon MTA:SA ?',
    'faq.3a': 'Non. San Andreas Online s’installe dans son propre dossier, séparé de MTA:SA : les deux peuvent cohabiter.',
    'faq.4q': 'C’est le MTA officiel ?',
    'faq.4a': 'Non. San Andreas Online est un projet indépendant basé sur le code open source de Multi Theft Auto: San Andreas. Il n’est ni géré, ni affilié, ni approuvé par l’équipe MTA.',
    'faq.5q': 'Pourquoi le téléchargement est sur GitHub ?',
    'faq.5a': 'GitHub héberge le code, et c’est là que chaque version est compilée et publiée. Le bouton de téléchargement te donne directement l’installateur : tu n’as jamais besoin de parcourir le code.',
    'faq.6q': 'Je peux héberger mon propre serveur ?',
    'faq.6a': 'Oui. Chaque version inclut des serveurs pour Windows x64, Linux x64 et Linux ARM64.',
    'faq.7q': 'Où trouver de l’aide ?',
    'faq.7a': 'Rejoins le Discord San Andreas Online. Joueurs, propriétaires de serveurs et développeurs s’y retrouvent.',
    'out.kicker': 'Grove Street. Home.',
    'out.title': 'Here we go again.',
    'out.discord': 'Rejoindre le Discord',
    'foot.docs': 'Documentation',
    'foot.releases': 'Toutes les versions',
    'foot.legal': 'San Andreas Online est un projet indépendant et open source basé sur Multi Theft Auto: San Andreas, distribué sous licence GPL-3.0. Il n’est ni affilié ni approuvé par l’équipe MTA, Rockstar Games ou Take-Two Interactive. Grand Theft Auto et San Andreas sont des marques de Take-Two Interactive. Une copie légale de GTA: San Andreas pour PC est requise.',
    'passed.big': 'Mission réussie !',
    'passed.small': 'Téléchargement lancé · Respect +',
    'meta.free': 'Gratuit',
    'meta.mb': 'Mo',
  };
  const EN_EXTRA = {
    'cmp.c1': 'Distant buildings stay detailed instead of melting into low-poly blobs.',
    'cmp.c2': 'Hundreds of distant lights: the whole city lights up at night.',
    'cmp.c3': 'Warmer, richer grading, the way it looked on PlayStation 2.',
    'meta.free': 'Free',
    'meta.mb': 'MB',
  };

  const nodes = [...document.querySelectorAll('[data-i18n]')];
  const EN = Object.fromEntries(nodes.map((n) => [n.dataset.i18n, n.innerHTML]));
  Object.assign(EN, EN_EXTRA);

  const store = {
    get(k) { try { return localStorage.getItem(k); } catch { return null; } },
    set(k, v) { try { localStorage.setItem(k, v); } catch { /* private mode */ } },
  };

  let lang = store.get('neon-lang') || ((navigator.language || '').toLowerCase().startsWith('fr') ? 'fr' : 'en');
  const t = (key) => (lang === 'fr' ? FR[key] : EN[key]) ?? EN[key] ?? key;

  const langBtn = document.getElementById('lang');
  function applyLang() {
    document.documentElement.lang = lang;
    for (const n of nodes) n.innerHTML = t(n.dataset.i18n);
    langBtn.textContent = lang === 'fr' ? 'EN' : 'FR';
    langBtn.setAttribute('aria-label', lang === 'fr' ? 'Switch to English' : 'Passer en français');
    renderMeta();
    setCaption();
  }
  langBtn.addEventListener('click', () => {
    lang = lang === 'fr' ? 'en' : 'fr';
    store.set('neon-lang', lang);
    applyLang();
  });

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
    'draw-distance': { cap: 'cmp.c1', a: 'Classic MTA:SA: distant buildings are low-detail blobs', b: 'San Andreas Online: distant buildings stay detailed' },
    project2dfx: { cap: 'cmp.c2', a: 'Classic MTA:SA at night: the skyline fades into fog', b: 'San Andreas Online at night: hundreds of distant city lights' },
    skygfx: { cap: 'cmp.c3', a: 'Classic MTA:SA street in Ganton with neutral colours', b: 'San Andreas Online street in Ganton with warm PS2-style colours' },
  };
  let cmpKey = 'draw-distance';

  function setCaption() {
    caption.innerHTML = t(CMP[cmpKey].cap);
    caption.dataset.i18n = CMP[cmpKey].cap;
  }
  range.addEventListener('input', () => box.style.setProperty('--pos', `${range.value}%`));
  tabs.forEach((tab) => tab.addEventListener('click', () => {
    cmpKey = tab.dataset.cmp;
    tabs.forEach((b) => { const on = b === tab; b.classList.toggle('is-active', on); b.setAttribute('aria-selected', String(on)); });
    imgA.src = `/assets/img/cmp-${cmpKey}-a.webp`;
    imgB.src = `/assets/img/cmp-${cmpKey}-b.webp`;
    imgA.alt = CMP[cmpKey].a;
    imgB.alt = CMP[cmpKey].b;
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

  applyLang();
})();

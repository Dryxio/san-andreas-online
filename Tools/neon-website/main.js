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
    'cmp.kicker': 'Sans mod',
    'cmp.title': 'Avant / après',
    'cmp.sub': 'Ce sont des options à activer ou non dans les paramètres. Fais glisser le curseur pour comparer avec le jeu original.',
    'cmp.t1': 'Distance d’affichage',
    'cmp.t2': 'Lumières de nuit',
    'cmp.t3': 'Couleurs PS2',
    'cmp.c1': 'Dans l’original, le bout de la ville n’est qu’un tas de blocs low-poly. Ici, les vrais bâtiments s’affichent jusqu’aux collines.',
    'cmp.c2': 'La nuit, toute la ville reste éclairée, pas seulement les quelques rues autour de toi.',
    'cmp.c3': 'Des couleurs plus chaudes, plus proches du jeu sur PS2.',
    'feat.kicker': 'Respect +',
    'feat.title': 'Ce qui change',
    'feat.1t': 'Des mondes plus grands',
    'feat.1d': 'Les serveurs peuvent créer des maps jusqu’à 20 × 20 km, plus de dix fois la surface de San Andreas, chargées par GTA comme la map d’origine.',
    'feat.2t': 'Les graphismes dans le menu',
    'feat.2d': 'Distance d’affichage, lumières au loin et couleurs PS2 sont de simples options. Pas d’ASI loader, pas de dossier de mods.',
    'feat.3t': 'Un menu façon San Andreas',
    'feat.3d': 'Le menu principal et le navigateur de serveurs sont refaits dans le style du jeu. La connexion Discord est là si tu la veux.',
    'feat.4t': 'Mises à jour automatiques',
    'feat.4d': 'Quand une nouvelle version sort, le launcher te la propose. Chaque mise à jour est signée, et un fichier qui ne correspond pas est refusé.',
    'feat.5t': 'Ton MTA:SA ne bouge pas',
    'feat.5d': 'San Andreas Online s’installe dans son propre dossier. Si tu joues déjà à MTA, rien ne change de ce côté.',
    'inst.kicker': 'Nouvelle mission',
    'inst.title': 'Dans la rue en 3 étapes',
    'inst.1t': 'Avoir GTA: San Andreas',
    'inst.1d': 'La version PC originale. La Definitive Edition ne marche pas.',
    'inst.2t': 'Télécharger San Andreas Online',
    'inst.2d': 'Un seul fichier : <b>MTA-Neon-Setup.exe</b> (Neon, c’est l’ancien nom du projet).',
    'inst.2b': 'Télécharger l’installateur',
    'inst.3t': 'Installer et jouer',
    'inst.3d': 'Lance-le, indique ton dossier GTA: San Andreas, puis choisis un serveur dans la liste.',
    'safe.t': 'Windows affiche « Windows a protégé votre ordinateur » ?',
    'safe.d': 'L’installateur n’est pas encore signé, donc SmartScreen affiche un avertissement. Clique sur <b>Informations complémentaires</b>, puis <b>Exécuter quand même</b>. Chaque version est compilée sur GitHub à partir du code source public, et les sommes SHA-256 sont publiées avec.',
    'safe.l': 'Voir les sommes de contrôle →',
    'cr.kicker': 'Pour les créateurs de serveurs',
    'cr.title': 'Plus de GTA, en Lua',
    'cr.sub': 'Culling, props du monde, collisions, feu, végétation, oiseaux : des parties du moteur que MTA n’a jamais ouvertes aux scripts. Toutes les captures ci-dessous viennent du jeu.',
    'cr.1t': 'Zones CULL natives',
    'cr.1d': 'Modifie le culling de GTA en Lua',
    'cr.2t': 'Objets du monde',
    'cr.2d': 'Suis, déplace et casse les props de SA',
    'cr.3t': 'Collisions à la volée',
    'cr.3d': 'Des collisions depuis une table Lua, sans .col',
    'cr.4t': 'Maps SA-MP',
    'cr.4d': 'Charge les exports de maps SA-MP tels quels',
    'cr.5t': 'Feu géré',
    'cr.5d': 'Des feux synchronisés qui suivent une cible',
    'cr.6t': 'Végétation',
    'cr.6d': 'Fais pousser la végétation de GTA partout',
    'cr.7t': 'Oiseaux scriptables',
    'cr.7d': '128 oiseaux à la fois, pilotés en Lua',
    'cr.8t': '2DFX des modèles',
    'cr.8d': 'Modifie les lumières et effets des modèles',
    'cr.docs': 'Doc et API Lua',
    'cr.server': 'Télécharger un serveur (Windows / Linux)',
    'faq.kicker': 'Avant que tu demandes',
    'faq.1q': 'C’est gratuit ?',
    'faq.1a': 'Oui. C’est open source sous licence GPL-3.0, comme Multi Theft Auto.',
    'faq.2q': 'Il me faut GTA: San Andreas ?',
    'faq.2a': 'Oui, la version PC originale. San Andreas Online ne contient pas le jeu, et la Definitive Edition ne marche pas.',
    'faq.3q': 'Ça remplace mon MTA:SA ?',
    'faq.3a': 'Non. Il a son propre dossier, tu peux garder les deux.',
    'faq.4q': 'C’est le MTA officiel ?',
    'faq.4a': 'Non. C’est un projet à part, basé sur le code open source de Multi Theft Auto. L’équipe MTA ne le gère pas et ne l’a pas approuvé.',
    'faq.5q': 'Il y a du trafic et des piétons ?',
    'faq.5a': 'Oui. Les voitures, piétons, gangs et flics de GTA, avec l’IA du mode solo et synchronisés pour que tout le monde voie la même rue. SA-MP et MTA les désactivent.',
    'faq.6q': 'Je peux héberger mon propre serveur ?',
    'faq.6a': 'Oui. Chaque version a des serveurs pour Windows x64, Linux x64 et Linux ARM64.',
    'faq.7q': 'Où trouver de l’aide ?',
    'faq.7a': 'Demande sur le Discord. Il y a un salon d’aide, et les gens qui font tourner les serveurs traînent aussi là-bas.',
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
      'nav.streets': 'Trafic',
    'hero.lede': 'Le multijoueur de GTA: San Andreas avec les rues du mode solo. Trafic, piétons, gangs et flics tournent sur l’IA de GTA, et tous les joueurs voient la même ville.',
    'st.kicker': 'Seulement sur San Andreas Online',
    'st.title': 'Les rues sont de nouveau pleines',
    'st.sub': 'SA-MP et MTA coupent le trafic et les piétons de GTA, donc leurs villes sont vides. San Andreas Online les remet avec l’IA du mode solo, synchronisés pour tout le serveur. Le serveur freeroam officiel le fait tourner en ce moment.',
    'st.1t': 'Les conducteurs de GTA',
    'st.1d': 'Voitures, vans, camions, motos, BMX et quads roulent avec la même IA qu’en solo.',
    'st.2t': 'Les gangs sur leur territoire',
    'st.2d': 'Les Grove, les Ballas et les autres tiennent les mêmes quartiers que dans l’histoire, et chaque ville a ses propres flics.',
    'st.3t': 'Une ville qui change',
    'st.3d': 'Qui traîne dehors dépend du quartier, de l’heure, du jour de la semaine et de la pluie, selon les règles du jeu.',
    'st.4t': 'Vole une caisse, ça réagit',
    'st.4d': 'Sors un conducteur de sa voiture : il peut fuir, se battre ou essayer de la récupérer.',
    'st.5t': 'La même rue pour tout le monde',
    'st.5d': 'Chaque voiture et chaque piéton est géré par le jeu d’un joueur et affiché en synchro chez les autres. Si ce joueur part, un autre prend le relais et rien ne disparaît.',
    'st.6t': 'Monte à bord',
    'st.6d': 'Prends une place passager libre et le conducteur continue sa route.',
};
  const EN_EXTRA = {
    'cmp.c1': 'In the original, the far side of town is a mess of low-detail boxes. Here the real buildings load all the way to the hills.',
    'cmp.c2': 'At night the whole skyline stays lit, not only the few blocks around you.',
    'cmp.c3': 'Warmer colours, closer to how the game looked on a PS2.',
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
    'draw-distance': { cap: 'cmp.c1', a: 'Original game: distant buildings are low-detail boxes', b: 'San Andreas Online: distant buildings stay detailed' },
    project2dfx: { cap: 'cmp.c2', a: 'Original game at night: the skyline fades into fog', b: 'San Andreas Online at night: hundreds of distant city lights' },
    skygfx: { cap: 'cmp.c3', a: 'Original game: a street in Ganton with neutral colours', b: 'San Andreas Online street in Ganton with warm PS2-style colours' },
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

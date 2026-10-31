# San Andreas Online website

Player-facing site for San Andreas Online (internal/code name: MTA Neon; the folder, repo, asset names and URLs keep "neon").

Static download page for players. No build step: `index.html`, `styles.css`, `main.js`.

- Artwork: SA loading screens already shipped by the client (`Tools/server-browser-prototype/public/loadscreens`), cropped to drop the baked-in GTA logo.
- Fonts: the client's own `Shared/data/MTA San Andreas/MTA/cgui/*.ttf`.
- Screenshots: `docs/media`.
- `/download` redirects to the latest `MTA-Neon-Setup.exe` release asset (see `vercel.json`).

Languages: `index.html` is the English source and `i18n/fr.json` holds the French text. After editing either, run `python3 build.py`: it writes `fr/index.html` (the French page at `/fr/`), the JSON-LD in both pages (FAQ read from the visible page) and `sitemap.xml` with hreflang alternates. Every element with `data-i18n` needs a French entry or the build stops. `llms.txt` is the plain-text summary for AI assistants; keep its facts in line with the page.

Deploy: `python3 build.py && vercel deploy --prod` from this folder.

Domain: `sanandreasonline.com` (registered at Namecheap, DNS records there point at Vercel). `www.` and the old `mtasa-neon.vercel.app` address redirect to it permanently so search engines index one address; `robots.txt` and `sitemap.xml` name it as well.

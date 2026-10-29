# San Andreas Online website

Player-facing site for San Andreas Online (internal/code name: MTA Neon; the folder, repo, asset names and URLs keep "neon").

Static download page for players. No build step: `index.html`, `styles.css`, `main.js`.

- Artwork: SA loading screens already shipped by the client (`Tools/server-browser-prototype/public/loadscreens`), cropped to drop the baked-in GTA logo.
- Fonts: the client's own `Shared/data/MTA San Andreas/MTA/cgui/*.ttf`.
- Screenshots: `docs/media`.
- `/download` redirects to the latest `MTA-Neon-Setup.exe` release asset (see `vercel.json`).

Deploy: `vercel deploy --prod` from this folder.

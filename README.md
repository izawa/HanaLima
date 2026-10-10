# HanaLima website (`gh-pages` branch)

This branch holds only the static teaser site for [HanaLima](https://github.com/izawa/HanaLima). The app's source code lives on `main`; the two branches share no history.

Published by GitHub Pages at **https://izawa.github.io/HanaLima/**
(Settings → Pages → Build and deployment → Source: *Deploy from a branch*, Branch: `gh-pages` / `/ (root)`).

## Layout

| File | Purpose |
|---|---|
| `index.html` | The whole page. Plain HTML, no build step. |
| `assets/css/site.css` | Styles. Colors are CSS variables on `:root`; dark is the default, light follows `prefers-color-scheme`. |
| `assets/js/site.js` | Language toggle, copy buttons, reveal-on-scroll. No dependencies. |
| `assets/img/logo.svg` | Logo and favicon: the app icon's SVG master (copied from `Resources/AppIcon/AppIcon.svg` on `main`). |
| `assets/img/icon-512.png`, `apple-touch-icon.png` | The app icon as PNG (hero, name section, Open Graph, iOS home screen). Regenerate from `Resources/AppIcon/AppIcon-1024.png` with `sips -z`. |
| `.nojekyll` | Serve files as-is (no Jekyll processing). |

## Editing rules

- **Every visible text exists in English and Japanese**: `<span class="en">…</span><span class="ja">…</span>` (or `div`/`p` with the same classes). CSS hides the inactive language; the choice is saved in `localStorage`.
- Keep claims factual and dated where it matters (e.g. "tested on macOS 27.0.1"). Link to `docs/` on `main` for details.
- Keep the "unofficial project" notice.

- **Bump the `?v=` on the stylesheet and script links in `index.html` whenever `site.css` or `site.js` changes.** GitHub Pages lets browsers cache them for 10 minutes, so new HTML could otherwise be drawn with the old CSS (the figures would render as black boxes).

## Growing the site with the app

When a feature ships on `main`:

1. **Features** (`#features`): copy a `.card`, set its badge to the version (`<span class="status done">v0.4</span>`), or add a planned one with `class="status next"`. Keep the grid free of a lone card in the last row: with 3 columns, a closing card can take the full row with `class="card reveal wide"`.
2. **Roadmap** (`#roadmap`): change the milestone's class from `next` to `done`, and mark the following one `next`. Postponed work uses `later` (cards: `class="status later"`).
3. **How it works** (`#how`): if the feature relies on a non-obvious technique, add an `article.dive` with the next number — a short explanation on the left, a concept figure (`figure.fig`, a small inline SVG) on the right. Keep each figure to one idea, ideally a before/after contrast.
4. **Comparison table** (`#networking`): add a row if the feature is network-related.

Screenshots can go in `assets/img/` (prefer 2× PNG or WebP, with `width`/`height` attributes).

## Preview locally

```bash
python3 -m http.server 8642 --directory .
```

Then open http://localhost:8642/.

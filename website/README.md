# Rtranslate product website

Dependency-free static landing page. This is a curated example animation, not a browser translation service. It does not request microphone access or call a translation API.

## Preview

```sh
python3 -m http.server 4173 --directory website
```

Open http://localhost:4173. Syntax validation: `node --check website/app.js`.

## Deploy

GitHub Pages is configured for Actions. Pushes to `main` affecting `website/` or `.github/workflows/pages.yml` automatically publish the `website` directory. Manual deployment is also available via the workflow's Run workflow button.

## Interaction

- Three example buttons and replay trigger progressive translated text.
- Output can switch between English, Japanese and French (preset translations).
- Canvas sentences accelerate into the center, shrink, then emerge translated.
- Pointer proximity pulls sentences toward the translation core.
- Pause control, reduced-motion preference, visibility changes and offscreen detection prevent unnecessary animation.
- Reduced-motion mode displays a static language pair and immediate example text.

Public installation links intentionally point to repository documentation; no release package is advertised because no GitHub release is currently published.

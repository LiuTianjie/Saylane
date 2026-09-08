# Rtranslate product website

Static product demo deployed to GitHub Pages. No microphone access or live translation API: all sentences are curated examples.

## Preview and validate

```sh
python3 -m http.server 4173 --directory website
node --check website/app.js
```

## Design

The title uses the product owner's supplied wording. The central voice capsule follows `Sources/Views/OverlayView.swift`: 234 × 40 capsule, 38 monochrome waveform bars, 2.6px width, 2.2px spacing, 4–20px native height range and edge attenuation. The website simulates audio levels, not actual microphone input.

Chinese sentences accelerate and stretch into the native voice capsule. English translations emerge on the right. Press and hold the capsule (pointer, touch, or focused Space/Enter) to intensify the flow and play another sample in the app input above it. Releasing restores normal speed. There are no language selectors or central logo cards.

The animation pauses offscreen or when the tab is hidden, supports a manual pause control, and respects reduced motion. Reduced-motion mode presents a static source/target pair.

## Publish

`.github/workflows/pages.yml` publishes only `website/` on relevant pushes to `main`, or through manual workflow dispatch. Native app source and build output are not included. Installation links lead to repository instructions, not a nonexistent release package.

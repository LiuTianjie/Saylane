# Rtranslate product website

Static product demo deployed to GitHub Pages. No microphone access or live translation API: all sentences are curated examples.

## Preview and validate

```sh
python3 -m http.server 4173 --directory website
node --check website/app.js
```

## Design

The title uses the product owner's supplied wording. The central voice capsule follows `Sources/Views/OverlayView.swift`: 234 × 40 capsule, 38 monochrome waveform bars, 2.6px width, 2.2px spacing, 4–20px native height range and edge attenuation. The website simulates audio levels, not actual microphone input. Waveform motion uses a separate, slower clock so holding the control accelerates the text without speeding up the waveform.

Chinese sentences move continuously, accelerate and uniformly shrink into the native voice capsule. English translations emerge on the right and uniformly grow. Text is never stretched, skewed, or duplicated into horizontal ghost trails. The scene deliberately has no guide lines, particle streaks or vertical connector. A separate uniformly scaled small-text stream fills the two zones immediately beside the capsule (28 additional desktop / 12 mobile sentences), leaving the outer readable stream unchanged. Each flowing sentence has a subtly filled chat-bubble outline (gray input, mint output), transformed together with the text. Sentences follow the local flow direction with a gentle rotation capped at 18 degrees while keeping their aspect ratio. Press and hold the capsule (pointer, touch, or focused Space/Enter) to intensify the flow and play another sample in the app input above it. Releasing restores normal speed. There are no language selectors or central logo cards.

The animation pauses offscreen or when the tab is hidden and respects reduced motion. Reduced-motion mode presents a static source/target pair.

## Publish

`.github/workflows/pages.yml` publishes only `website/` on relevant pushes to `main`, or through manual workflow dispatch. Native app source and build output are not included. The download section links to the published v0.2.45 PKG, release notes, SHA-256 checksums and installation guide. It explicitly states the installer is unsigned and not notarized. When publishing a new version, update these version-pinned links and size together.

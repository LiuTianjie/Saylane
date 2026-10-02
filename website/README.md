# Saylane product website

Static product page deployed to GitHub Pages. No microphone access and no live translation: every sentence and every picture on it is a preset example.

## Preview and validate

```sh
python3 -m http.server 4173 --directory website
node --check website/app.js website/practice.js website/site.js
python3 Tests/BrandingTests.py
```

## What is on the page

| Part | Files | Notes |
| --- | --- | --- |
| Hero: title, chat window, flowing sentences, voice capsule | `index.html`, `app.js` | The title and tagline are the product owner's wording. The capsule follows `Sources/Views/OverlayView.swift`: 234 × 40, 38 bars. Hold it (pointer, touch, Space/Enter) to speed the flow up and play another sample. |
| Dictation: live words, then the final text | `site.js` | A few characters about every 0.26 s, then the final text with what changed marked. The three figures come from `docs/SPEECH_PIPELINE.md`; change them only together with that document. |
| Three steps | `index.html` | |
| Language modes | `practice.js` | Mirrors `TranslationDirection.voiceModes`: A→A, A→B, B→A, B→B. Double-click the key, or use the four buttons. |
| Translating what is on screen | `index.html`, `site.js` | Four scenes (web page, software, picture, video), each drawn twice in HTML/CSS with the same fixed layout: as it is, and translated. A region is selected and shows the second. No image files. The section is named "所见即译" on the page; the settings still call the feature "截屏翻译". |
| Pinyin | `site.js` | A composition and its candidates. |
| Privacy, questions, download | `index.html`, `site.js` | |

## Writing for the page

Few words, no labels: no badges, chips, tag pills or icon cards. A section is a heading, one or two sentences and one demonstration. Details belong in the README and `docs/`.

Every claim on the page has to be true of the published release. The demonstrations are marked as preset ("预设的演示").

## Download block

The page names no version. The button and the release-notes link lead to `releases/latest`; when the page loads, `site.js` asks GitHub's API for the latest release and fills in its version, the size and the direct link to its `.pkg`. If that request fails the links still lead to the releases page. So the page cannot fall behind a release — but it also describes the current product, so publish the page together with a release that has what it shows.

## Motion and accessibility

Demos run only while they are on screen and the page is visible, and start over when they come back. With reduced motion every demo shows its end state and nothing moves. All text has a base size of 15–16 px; the chat window and the four scenes are miniatures with their own small type.

## Publish

`.github/workflows/pages.yml` publishes only `website/` on pushes to `main` that touch it, or through manual workflow dispatch. Native app source and build output are not included.

## Brand assets

The header, footer and browser icons reuse the native app's waveform artwork. `assets/brand-icon.png` is copied from `Sources/Resources/AppIcon.iconset/icon_128x128@2x.png` (256px); `favicon.png` and `favicon-64.png` use the native 32px and 64px exports. No separate logo is introduced.

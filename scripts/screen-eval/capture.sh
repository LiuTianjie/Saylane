#!/bin/bash
# Take the sample pictures with their truth: real bilingual pages and the
# fixture, at 1x and 2x. Output: build/screen-eval/pages/<name>-<lang>@<scale>x.{png,json}
set -euo pipefail
cd "$(dirname "$0")/../.."
S=build/screen-eval/snapshot
P=build/screen-eval/pages
mkdir -p "$P"
shoot() { # name url [width height]
  for scale in 2 1; do "$S" "$2" "${3:-1280}" "${4:-900}" "$scale" "$P/$1@${scale}x" | tail -1; done
}
F="file://$PWD/scripts/screen-eval/fixtures/app.html"
shoot app-en "$F?lang=en" 1200 1010
shoot app-zh "$F?lang=zh" 1200 1010
shoot appdark-en "$F?lang=en&theme=dark" 1200 1010
shoot appdark-zh "$F?lang=zh&theme=dark" 1200 1010
# The same page as its publisher localised it.
shoot apple-en  "https://support.apple.com/en-us/guide/mac-help/mh26782/mac"
shoot apple-zh  "https://support.apple.com/zh-cn/guide/mac-help/mh26782/mac"
shoot ghdocs-en "https://docs.github.com/en/get-started/start-your-journey/about-github-and-git"
shoot ghdocs-zh "https://docs.github.com/zh/get-started/start-your-journey/about-github-and-git"
shoot mdn-en    "https://developer.mozilla.org/en-US/docs/Web/CSS/font-size"
shoot mdn-zh    "https://developer.mozilla.org/zh-CN/docs/Web/CSS/font-size"
shoot vue-en    "https://vuejs.org/guide/introduction.html"
shoot vue-zh    "https://cn.vuejs.org/guide/introduction.html"

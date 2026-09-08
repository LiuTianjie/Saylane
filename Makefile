APP_NAME=RTranslate
DERIVED=build

.PHONY: generate build release pkg open-pkg test clean

generate:
	xcodegen generate

build: generate
	xcodebuild -project RTranslate.xcodeproj -scheme RTranslate -configuration Debug -destination 'platform=macOS' -derivedDataPath $(DERIVED) build

release: generate
	xcodebuild -project RTranslate.xcodeproj -scheme RTranslate -configuration Release -destination 'platform=macOS' -derivedDataPath $(DERIVED) build

pkg: release
	scripts/package.sh

open-pkg: pkg
	open "$$(ls -t dist/$(APP_NAME)-*.pkg | head -n 1)"

test:
	scripts/test.sh

clean:
	rm -rf build dist RTranslate.xcodeproj

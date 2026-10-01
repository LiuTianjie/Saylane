APP_NAME=Saylane
DERIVED=build
export TZ := Asia/Shanghai

.PHONY: generate build release pkg pkg-local open-pkg test clean

generate:
	scripts/generate-project.sh

build: generate
	xcodebuild -project Saylane.xcodeproj -scheme Saylane -configuration Debug -destination 'platform=macOS' -derivedDataPath $(DERIVED) build

release: generate
	xcodebuild -project Saylane.xcodeproj -scheme Saylane -configuration Release -destination 'platform=macOS' -derivedDataPath $(DERIVED) build

pkg: release
	scripts/package.sh

# Installer for testing on this Mac: unsigned package, never the release name.
pkg-local: release
	scripts/package-local.sh

open-pkg: pkg
	open "$$(ls -t dist/$(APP_NAME)-*.pkg | head -n 1)"

test:
	scripts/test.sh

clean:
	rm -rf build dist Saylane.xcodeproj

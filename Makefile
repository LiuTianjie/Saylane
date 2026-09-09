APP_NAME=Saylane
DERIVED=build

.PHONY: generate build release pkg open-pkg test clean

generate:
	scripts/generate-project.sh

build: generate
	xcodebuild -project Saylane.xcodeproj -scheme Saylane -configuration Debug -destination 'platform=macOS' -derivedDataPath $(DERIVED) build

release: generate
	xcodebuild -project Saylane.xcodeproj -scheme Saylane -configuration Release -destination 'platform=macOS' -derivedDataPath $(DERIVED) build

pkg: release
	scripts/package.sh

open-pkg: pkg
	open "$$(ls -t dist/$(APP_NAME)-*.pkg | head -n 1)"

test:
	scripts/test.sh

clean:
	rm -rf build dist Saylane.xcodeproj

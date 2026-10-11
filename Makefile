SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c

VERSION ?=
BUILD ?=
TAG ?=
DMG := build/Soundboard.dmg

export SOUNDBOARD_VERSION = $(VERSION)
export SOUNDBOARD_BUILD = $(BUILD)

.PHONY: test app install dmg check-version tag upload-dmg

test:
	swift test

app:
	./build.sh

install:
	./build.sh --install

dmg: app
	rm -rf build/dmg $(DMG)
	mkdir -p build/dmg
	cp -R build/Soundboard.app build/dmg/
	ln -s /Applications build/dmg/Applications
	hdiutil create -volname Soundboard -srcfolder build/dmg -format UDZO -fs HFS+ $(DMG)
	rm -rf build/dmg

check-version:
	@[[ "$(VERSION)" =~ ^[0-9]+(\.[0-9]+)*$$ ]] || { echo "VERSION must look like 1.2.0 (got '$(VERSION)')" >&2; exit 1; }
	@if git ls-remote --exit-code --tags origin "refs/tags/v$(VERSION)" >/dev/null; then echo "v$(VERSION) already exists" >&2; exit 1; fi

tag: check-version
	git tag "v$(VERSION)"
	git push origin "refs/tags/v$(VERSION)"

upload-dmg:
	@[[ -n "$(TAG)" ]] || { echo "TAG is required" >&2; exit 1; }
	gh release upload "$(TAG)" $(DMG) --clobber

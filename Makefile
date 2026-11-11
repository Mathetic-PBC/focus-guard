# Signing with a real identity keeps macOS permissions across rebuilds. With
# none on the machine the build is ad-hoc signed, and macOS asks again for
# browser access after each install.
IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ {print $$2; exit}')
ifeq ($(strip $(IDENTITY)),)
IDENTITY := -
endif

BUILD := build
APP := $(BUILD)/Build/Products/Release/FocusGuard.app
DEBUG_APP := $(BUILD)/Build/Products/Debug/FocusGuard.app
DEST := /Applications/FocusGuard.app
XCODEBUILD := xcodebuild -project FocusGuard.xcodeproj -scheme FocusGuard -derivedDataPath $(BUILD) \
	CODE_SIGN_IDENTITY="$(IDENTITY)" -quiet

.PHONY: project build debug test install uninstall clean

project:
	xcodegen generate --quiet

build: project
	$(XCODEBUILD) -configuration Release build

debug: project
	$(XCODEBUILD) -configuration Debug build

test:
	cd Core && swift test

install: build
	rm -rf "$(DEST)"
	ditto "$(APP)" "$(DEST)"
	-pkill -x FocusGuard
	open "$(DEST)"

uninstall:
	-launchctl bootout gui/$$(id -u)/com.mathetic.FocusGuard.agent
	-pkill -x FocusGuard
	rm -rf "$(DEST)"

clean:
	rm -rf $(BUILD) Core/.build FocusGuard.xcodeproj

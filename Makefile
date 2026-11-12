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

# xcodebuild registers each product with macOS as an installed app. Left
# registered, a build-folder copy can be the one macOS starts for a
# focusguard:// link, instead of the copy in /Applications.
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
UNREGISTER = -$(LSREGISTER) -u "$(CURDIR)/$(APP)" "$(CURDIR)/$(DEBUG_APP)" 2>/dev/null

.PHONY: project build debug test install uninstall clean

project:
	xcodegen generate --quiet

build: project
	$(XCODEBUILD) -configuration Release build
	$(UNREGISTER)

debug: project
	$(XCODEBUILD) -configuration Debug build
	$(UNREGISTER)

test:
	cd Core && swift test

install: build
	rm -rf "$(DEST)"
	ditto "$(APP)" "$(DEST)"
	-pkill -x FocusGuard
	sleep 2; pgrep -x FocusGuard >/dev/null || open "$(DEST)"

uninstall:
	-launchctl bootout gui/$$(id -u)/com.mathetic.FocusGuard.agent
	-pkill -x FocusGuard
	-networksetup -listallnetworkservices | tail -n +2 | grep -v '^\*' | while read -r s; do \
		networksetup -getautoproxyurl "$$s" | grep -q '127.0.0.1:47113' && networksetup -setautoproxystate "$$s" off; done
	rm -rf "$(DEST)"

clean:
	rm -rf $(BUILD) Core/.build FocusGuard.xcodeproj

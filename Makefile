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

# xcodebuild registers each product with macOS as an installed app. A second
# registered copy with the installed app's identifier is one macOS may start
# in its place: for a focusguard:// link, or as the copy it keeps alive. So
# the release product is unregistered and removed once it has been installed.
# (Debug builds carry their own identifier and can stay.) The unregister is
# given ten seconds: lsregister can hang on a path that is already gone.
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

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
	-perl -e 'alarm 10; exec @ARGV' $(LSREGISTER) -u "$(CURDIR)/$(APP)" 2>/dev/null
	rm -rf "$(APP)"
	-pkill -x FocusGuard
	sleep 2; pgrep -x FocusGuard >/dev/null || open "$(DEST)"
	# Replacing the app makes macOS drop its Focus filter from the index, and
	# until the installed copy is registered again macOS answers "no Focus"
	# to it. Registering only takes once the new copy is running.
	sleep 2
	-perl -e 'alarm 15; exec @ARGV' $(LSREGISTER) -f "$(DEST)" 2>/dev/null

uninstall:
	-launchctl bootout gui/$$(id -u)/com.mathetic.FocusGuard.agent
	-pkill -x FocusGuard
	-networksetup -listallnetworkservices | tail -n +2 | grep -v '^\*' | while read -r s; do \
		networksetup -getautoproxyurl "$$s" | grep -q '127.0.0.1:47113' && networksetup -setautoproxystate "$$s" off; done
	rm -rf "$(DEST)"

clean:
	rm -rf $(BUILD) Core/.build FocusGuard.xcodeproj

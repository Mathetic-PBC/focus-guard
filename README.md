# focus-guard

Blocks websites and apps on a Mac for as long as a Focus is on, and makes
switching that Focus off take two minutes instead of one click.

- **Profiles** hold the rules: a list of websites and a list of apps, each
  either "block these" or "allow only these".
- **Connecting** a profile to a Focus is done in System Settings. From then on
  the profile's rules are in force whenever that Focus is on, however it was
  switched on: by hand, on a schedule, or from another device.
- **Switching the Focus off** starts a countdown. Blocking stays on until it
  finishes. A panel shows the time left and a **Stay Focused** button that
  calls the whole thing off. The panel can be dragged out of the way and
  comes up in the same place next time.
- **Quitting** the app doesn't end a session. macOS restarts it, and a
  restart during a countdown begins the countdown again.

- **Posts to X can still be written.** While X is blocked, a drafts window
  takes the text, with tags, and keeps it on the Mac. When the session ends
  the drafts come up to be posted or deleted.

The repository ships no rules. On first run the app asks you to make a
profile, fill in its lists, and connect it to a Focus.

## Install

Needs macOS 14 or later, Xcode, and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

    make install

This builds the app, copies it to `/Applications/FocusGuard.app` and opens it.
A shield appears in the menu bar and the settings window opens.

## Set up

1. **Make a profile.** Add websites (`x.com`, `mail.google.com`, or a single
   path such as `linkedin.com/feed`) and apps.
2. **Connect it to a Focus.** In System Settings › Focus, choose the Focus,
   click **Add Filter** under Focus Filters, choose **Focus Guard**, and set
   Profile to the one you made. Repeat for any other Focus, with the same
   profile or a different one.
3. **Let it read your browsers.** In the Setup pane, click **Allow…** next to
   each browser. macOS asks once per browser.
4. **Switch the Focus on once.** The profile shows "Switched on by a Focus"
   when the connection works.
5. **Optional: cover WebKit apps.** Built-in browsers in Chromium-based apps
   (Claude, Engelbart, Cursor and other Electron apps) are covered with no
   setup. For WebKit-based apps (Codex, and web views in native Mac apps),
   click **Set Up…** under "Built-in browsers in other apps" and enter your
   password once.

Rules can't be edited while a session is running.

### Keeping the Focus itself on during the countdown

Blocking lasts through the countdown with no further setup. The Focus in the
menu bar, though, goes off the moment you click it, and notifications come
back for those two minutes.

macOS lets an app switch a Focus only through Shortcuts. Each profile's page
lists two shortcut names and has an **Add Shortcuts…** button that creates
them. With both in place, Focus Guard switches the Focus back on when you
click it off, and switches it off itself when the countdown ends.

## How it works

**Knowing when a Focus is on.** The app declares a Focus Filter, the interface
macOS gives apps for reacting to Focus changes. macOS calls it with the chosen
profile when the Focus goes on, and again when it goes off. The app also asks
macOS for the current filter, every three seconds when idle and every second
during a session, to catch a change it was not told about. During a session a
single "no Focus" answer is not acted on; two in a row are.

**Websites.** Every three quarters of a second the app asks the frontmost
browser, over AppleScript, for the address of the tab showing in each window. Other
running browsers are asked every three seconds, and background tabs twice a
minute. A tab on a blocked address is sent to a local page that says so.

**Built-in browsers in other apps.** An app with a web view of its own has no
tabs to read. So while a session is on, macOS is also pointed at a proxy
auto-config file served by Focus Guard. Every request from every app that
follows the system proxy settings is run through it. Requests for a blocked
host go to a listener in Focus Guard, which opens the tunnel and drops it;
everything else connects as it always does. Only whole hosts from a block
list are enforced this way: an encrypted request doesn't show its path, and
an allow list applied to the whole Mac would cut off every app's own traffic.

Chromium gives up when the tunnel drops. Apple's networking retries directly,
unless the network service has direct fallback switched off, which is the one
setting that needs a password and is changed only from the Setup pane.

**Drafts for X.** The page a blocked X tab is sent to links to a drafts
window, which is also in the menu bar menu. Drafts are a file on this Mac,
with their images in a folder beside it. Up to four images can be attached
by choosing, dropping or pasting them. Links and tags are coloured as they
are typed, and a link counts as 23 characters, as it does on X.

Typing `@` brings up a list of people, name over handle, matched against the
start of the handle or of any word of the name. The arrow keys move through
it and Return or Tab takes the highlighted one. The list is searched on this
Mac, because X can't be asked who exists while it is blocked, and its user
search is not open to apps without a paid API key. It holds everyone tagged
in an earlier draft, and it can be filled from your browser: **Import
People…** reads the address and title of X profile pages in the history of
Chrome and browsers built on it, which is where the names come from. It runs
only when asked and nothing it reads leaves the Mac. Someone you have never
visited or tagged has to be typed in full.

Post is disabled for as long as the rules in force block x.com. When that
stops being true, the window opens by itself with the drafts first. Post
opens X's own compose page with the text filled in, in your browser. That
address can't carry images, so a draft's images are put on the clipboard and,
once X's box has loaded, the browser is told to paste them, as ⌘V would. That
works in Chrome and browsers built on it. Where Chrome's View › Developer ›
Allow JavaScript from Apple Events is on, Focus Guard also puts the caret in
the box first and checks afterwards that the images are showing; where it is
off, the paste is made unchecked. In other browsers the images wait on the
clipboard for you to paste. The draft stays until you mark it posted. Focus
Guard never presses Post, sends nothing to X itself, and holds no X
credentials.

**Apps.** An app on a block list is asked to quit when the session starts and
each time it is opened. One opened during a session is forced if it doesn't
go. One that was already open is hidden instead, since it may be waiting on a
"save changes?" sheet. Under an allow list, every other app is hidden whenever
it comes to the front, and is left running.

**The countdown.** A small state machine in `Core/` decides when rules are in
force. It has three states (idle, active, cooling down) and no way from active
to idle that doesn't pass through cooling down.

**Staying alive.** The app registers itself as a background item, so macOS
starts it at login and restarts it within a second if it is killed. The session
is saved to disk on every change.

## What it does not do

- **It is not instant.** A blocked page can be on screen for up to three
  quarters of a second before it is replaced.
- **It reads Chrome, Chromium, Brave, Edge, Vivaldi, Opera and Safari.**
  Firefox, Arc, Zen, DuckDuckGo, Orion and other browsers that don't report
  their tabs are closed while a profile with website rules is on. A browser
  missing from both lists in `App/Sources/Browsers.swift` is not handled.
- **Inside other apps, only whole hosts on a block list are refused.** Path
  rules and allow lists work in browsers only. An app that ignores the system
  proxy settings is not covered, and neither is a site's own desktop app,
  which has to be on the app list.
- **With WebKit coverage on, the proxy setting must not outlive the app.**
  Focus Guard takes the setting down when it is asked to stop, and macOS
  restarts it within a second if it is killed. If it is ever gone for good
  during a session, Safari and other WebKit apps show every site as offline
  until Automatic Proxy Configuration is switched off under System Settings ›
  Network › Details › Proxies. `make uninstall` does that for you.
- **A proxy file you already use is left alone.** If a network service has its
  own auto-config address, Focus Guard doesn't replace it, and the block
  inside other apps isn't in force on that service.
- **It can be removed.** Deleting the filter in System Settings, or unloading
  the background item from Terminal, ends blocking with no countdown. The aim
  is to make stopping a deliberate act, not an impossible one.
- **A Focus ending on a schedule is treated like one switched off by hand.**
  The countdown runs after it.

## Files

Rules, session state, drafts and a log live in
`~/Library/Application Support/FocusGuard/`. The log records each Focus
change, each session, and each page and app blocked.

## Development

    make test     # state machine and rule matching
    make debug    # debug build in build/
    make install  # release build into /Applications
    make uninstall

Debug builds listen for a distributed notification that stands in for macOS
switching a Focus, so a session can be driven from a script. Release builds
don't contain it. A debug build is a separate app to macOS, with its own
bundle identifier, and refuses to start unless `FOCUSGUARD_HOME` points it at
a folder of its own, so it can't touch the installed copy's rules or session.

    FOCUSGUARD_HOME=/tmp/fg build/Build/Products/Debug/FocusGuard.app/Contents/MacOS/FocusGuard &
    osascript -l JavaScript -e 'ObjC.import("Foundation");
      $.NSDistributedNotificationCenter.defaultCenter
        .postNotificationNameObjectUserInfoDeliverImmediately(
          "com.mathetic.FocusGuard.debug", "on:My Profile", $(), true)'

The commands are `on:<profile name>`, `off`, `stay` and `end`.

## License

MIT

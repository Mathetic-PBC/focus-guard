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
  calls the whole thing off.
- **Quitting** the app doesn't end a session. macOS restarts it, and a
  restart during a countdown begins the countdown again.

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
macOS for the current filter every three seconds, to catch a change it was not
running for.

**Websites.** Every three quarters of a second the app asks the frontmost
browser, over AppleScript, for the address of the tab showing in each window. Other
running browsers are asked every three seconds, and background tabs twice a
minute. A tab on a blocked address is sent to a local page that says so.

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
- **It doesn't block the network.** Only browser tabs are checked. A blocked
  site's desktop app has to be on the app list as well.
- **It can be removed.** Deleting the filter in System Settings, or unloading
  the background item from Terminal, ends blocking with no countdown. The aim
  is to make stopping a deliberate act, not an impossible one.
- **A Focus ending on a schedule is treated like one switched off by hand.**
  The countdown runs after it.

## Files

Rules, session state and a log live in
`~/Library/Application Support/FocusGuard/`. The log records each Focus
change, each session, and each page and app blocked.

## Development

    make test     # state machine and rule matching
    make debug    # debug build in build/
    make install  # release build into /Applications
    make uninstall

Debug builds listen for a distributed notification that stands in for macOS
switching a Focus, so a session can be driven from a script. Release builds
don't contain it. Setting `FOCUSGUARD_HOME` points a run at its own folder
and keeps it apart from the installed copy.

    FOCUSGUARD_HOME=/tmp/fg build/Build/Products/Debug/FocusGuard.app/Contents/MacOS/FocusGuard &
    osascript -l JavaScript -e 'ObjC.import("Foundation");
      $.NSDistributedNotificationCenter.defaultCenter
        .postNotificationNameObjectUserInfoDeliverImmediately(
          "com.mathetic.FocusGuard.debug", "on:My Profile", $(), true)'

The commands are `on:<profile name>`, `off`, `stay` and `end`.

## License

MIT

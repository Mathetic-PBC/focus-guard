import AppKit
import FocusGuardCore
import SwiftUI

@main
struct FocusGuardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
        } label: {
            MenuLabel()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static var settingsWindow: NSWindow?
    private static var draftsWindow: NSWindow?
    private var poweringOff = false
    private var terminateSource: DispatchSourceSignal?
    private var lastLinkOpened: Date?
    private var isPrimary = false
    private var pendingLinks: [URL] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A run pointed at its own folder is a test. It stays out of the way
        // of the installed copy, and the installed copy out of its.
        if !Paths.isOverridden {
            guard SingleInstance.claim() else {
                // Another copy is already doing the work. Give a link time to
                // arrive, pass on what this copy was started for, and leave.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
                    SingleInstance.handOver(links: pendingLinks)
                    exit(0)
                }
                return
            }
            SingleInstance.listen(
                onShowSettings: { AppDelegate.showSettings() },
                onLink: { [weak self] url in self?.open(url) })
        }
        isPrimary = true
        pendingLinks.forEach(open)
        pendingLinks = []

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.poweringOff = true }
        }

        let session = SessionController.shared
        // When a session that kept X out of reach ends, anything drafted in
        // the meantime is put in front of the person to post or delete.
        session.onXUnblocked = {
            guard DraftsModel.shared.count > 0 else { return }
            AppDelegate.showDrafts(reviewing: true)
        }
        session.start()

        // The page a blocked X tab is sent to links here, as focusguard://drafts.
        // SwiftUI installs its own handler for links while the app starts and
        // has no window to give this one to, so ours goes in after it.
        DispatchQueue.main.async {
            NSAppleEventManager.shared().setEventHandler(
                self, andSelector: #selector(self.handleURL(_:reply:)),
                forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        }

        // A kill request ends the process without the usual goodbye. The
        // system proxy setting must not outlive the listener it points at, so
        // it is taken down first. macOS then restarts the app, which puts the
        // setting back if a session is running.
        signal(SIGTERM, SIG_IGN)
        let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        terminate.setEventHandler {
            Log.write("stop requested; releasing the proxy setting")
            SessionController.shared.prepareToExit()
            exit(0)
        }
        terminate.resume()
        terminateSource = terminate

        // First run from an installed copy: ask macOS to keep the app alive.
        // If that works, macOS starts its own copy and this one steps aside.
        if Background.isInstalledCopy, !Paths.isOverridden, !Background.isAgentProcess, !Background.isEnabled,
           !UserDefaults.standard.bool(forKey: "backgroundOffered") {
            UserDefaults.standard.set(true, forKey: "backgroundOffered")
            do {
                try Background.enable()
            } catch {
                Log.write("background: could not register: \(error)")
            }
        }

        if Background.isTakeover {
            AppDelegate.showSettings()
        } else if session.config.profiles.isEmpty {
            // Give a freshly registered background copy a moment to take over
            // before a window is opened in this one.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { AppDelegate.showSettings() }
        }
    }

    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: text)
        else { return }
        open(url)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(open)
    }

    private func open(_ url: URL) {
        guard url.scheme == "focusguard" else { return }
        guard isPrimary else {
            pendingLinks.append(url)
            return
        }
        lastLinkOpened = Date()
        if url.host == "drafts" { AppDelegate.showDrafts(reviewing: false) }
    }

    /// Opening the app again from Finder shows its settings. macOS sends the
    /// same "reopen" when a link is what brought the app forward, so this
    /// waits a moment to see whether a link follows.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            if let opened = self?.lastLinkOpened, Date().timeIntervalSince(opened) < 2 { return }
            AppDelegate.showSettings()
        }
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if SessionController.shared.isLocked, !poweringOff {
            Log.write("quit refused: a session is running")
            return .terminateCancel
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        SessionController.shared.prepareToExit()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    static func showDrafts(reviewing: Bool) {
        DraftsModel.shared.reviewing = reviewing
        if draftsWindow == nil {
            let root = DraftsView().environmentObject(SessionController.shared)
            let window = NSWindow(contentViewController: NSHostingController(rootView: root))
            window.title = "Drafts for X"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 580, height: 620))
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("FocusGuardDrafts")
            draftsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        draftsWindow?.makeKeyAndOrderFront(nil)
    }

    static func showSettings() {
        if settingsWindow == nil {
            let root = SettingsView().environmentObject(SessionController.shared)
            let window = NSWindow(contentViewController: NSHostingController(rootView: root))
            window.title = "Focus Guard"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.setContentSize(NSSize(width: 900, height: 660))
            window.contentMinSize = NSSize(width: 760, height: 520)
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("FocusGuardSettings")
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        SessionController.shared.refreshShortcuts()
    }
}

#if DEBUG
extension AppDelegate {
    /// Draws the settings window into a PNG, so a build can be looked at
    /// without permission to record the screen.
    static func snapshotSettings(to path: String) {
        showSettings()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard let view = settingsWindow?.contentView?.superview ?? settingsWindow?.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            Log.write("debug: snapshot written")
        }
    }

    static func snapshotDrafts(to path: String) {
        if draftsWindow == nil || draftsWindow?.isVisible == false {
            showDrafts(reviewing: DraftsModel.shared.reviewing)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard let view = draftsWindow?.contentView?.superview ?? draftsWindow?.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            Log.write("debug: drafts snapshot written")
        }
    }
}
#endif

struct MenuLabel: View {
    @ObservedObject private var session = SessionController.shared

    var body: some View {
        switch session.state {
        case .idle:
            Image(systemName: "shield")
                .accessibilityLabel("Focus Guard, nothing blocked")
        case .active:
            Image(systemName: "shield.fill")
                .accessibilityLabel("Focus Guard, blocking")
        case .coolingDown:
            HStack(spacing: 4) {
                Image(systemName: "hourglass")
                Text(formatCountdown(session.remaining ?? 0)).monospacedDigit()
            }
            .accessibilityLabel("Focus Guard, cooling down")
        }
    }
}

struct MenuContent: View {
    @ObservedObject private var session = SessionController.shared
    @ObservedObject private var drafts = DraftsModel.shared

    var body: some View {
        switch session.state {
        case .idle:
            Text("Nothing is blocked")
        case .active:
            let profile = session.activeProfile
            Text("Blocking: \(profile?.name ?? "profile")")
            Button("End Session… (\(formatDuration(profile?.cooldownSeconds ?? Profile.defaultCooldown)) wait)") {
                session.requestEnd()
            }
        case .coolingDown:
            Text("\(session.activeProfile?.name ?? "Session") ends in \(formatCountdown(session.remaining ?? 0))")
            Button("Stay Focused") { session.cancelCooldown() }
        }
        Divider()
        Button(drafts.count == 0 ? "Drafts for X…" : "Drafts for X… (\(drafts.count))") {
            AppDelegate.showDrafts(reviewing: false)
        }
        Button("Settings…") { AppDelegate.showSettings() }
        if !Background.isEnabled {
            Divider()
            Button("Quit Focus Guard") { NSApp.terminate(nil) }
                .disabled(session.isLocked)
        }
    }
}

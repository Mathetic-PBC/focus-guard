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
    private var poweringOff = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A run pointed at its own folder is a test. It stays out of the way
        // of the installed copy, and the installed copy out of its.
        if !Paths.isOverridden {
            guard SingleInstance.claim() else {
                exit(0)
            }
            SingleInstance.listen { AppDelegate.showSettings() }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.poweringOff = true }
        }

        let session = SessionController.shared
        session.start()

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

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        AppDelegate.showSettings()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if SessionController.shared.isLocked, !poweringOff {
            Log.write("quit refused: a session is running")
            return .terminateCancel
        }
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
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
        Button("Settings…") { AppDelegate.showSettings() }
        if !Background.isEnabled {
            Divider()
            Button("Quit Focus Guard") { NSApp.terminate(nil) }
                .disabled(session.isLocked)
        }
    }
}

import AppKit
import ServiceManagement

/// Keeping the app alive. Registered as a background item, macOS starts it at
/// login and starts it again if it is quit or killed. Without that, force-quit
/// would be a one-step way around every rule.
enum Background {
    static let label = "com.mathetic.FocusGuard.agent"
    private static var service: SMAppService { SMAppService.agent(plistName: "\(label).plist") }

    /// True in the copy that macOS started as the background item.
    static let isAgentProcess = ProcessInfo.processInfo.environment["FOCUSGUARD_AGENT"] == "1"

    static var isEnabled: Bool { service.status == .enabled }

    static var statusText: String {
        switch service.status {
        case .enabled: return "On. macOS starts Focus Guard at login and restarts it if it stops."
        case .requiresApproval: return "Waiting for approval in System Settings › General › Login Items & Extensions."
        case .notRegistered: return "Off. Force-quitting Focus Guard ends blocking at once."
        case .notFound: return "Unavailable in this copy of the app."
        @unknown default: return "Unknown."
        }
    }

    static func enable() throws {
        try service.register()
        Log.write("background: registered, status \(service.status.rawValue)")
    }

    /// Registers again from scratch. For when macOS says the background item
    /// is on but isn't running it, which happens if the registration came to
    /// point at a copy of the app that no longer exists.
    static func repair() {
        Log.write("background: registered but not running; registering again")
        try? service.unregister()
        // macOS needs a moment between the two, or the second is refused.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            do {
                try service.register()
                Log.write("background: registered again, status \(service.status.rawValue)")
            } catch {
                Log.write("background: could not register again: \(error)")
            }
        }
    }

    /// Passed to a copy that is started to carry on after the background copy
    /// is unregistered.
    static let takeoverFlag = "--takeover"
    static let isTakeover = CommandLine.arguments.contains(takeoverFlag)

    /// Unregistering makes macOS stop the background copy, which is usually
    /// this process. So an ordinary copy is started first, to take over the
    /// menu bar and the settings window; then this one lets itself be stopped.
    static func disable(completion: @escaping (Error?) -> Void) {
        Log.write("background: unregistering")
        guard isAgentProcess else {
            do {
                try service.unregister()
                completion(nil)
            } catch {
                completion(error)
            }
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = [takeoverFlag]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                do {
                    try service.unregister()
                    completion(nil)
                } catch {
                    completion(error)
                }
            }
        }
    }

    /// Only an installed copy registers itself. A build run from a build
    /// folder would otherwise leave macOS restarting a path that moves.
    static var isInstalledCopy: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }
}

/// Makes sure one copy runs, and that it is the one macOS keeps alive.
enum SingleInstance {
    static let yield = Notification.Name("com.mathetic.FocusGuard.yield")
    static let showSettings = Notification.Name("com.mathetic.FocusGuard.showSettings")
    static let openLink = Notification.Name("com.mathetic.FocusGuard.openLink")

    private static var others: [NSRunningApplication] {
        guard let bundleID = Bundle.main.bundleIdentifier else { return [] }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != getpid() }
    }

    /// Returns false when this copy should exit and leave the field to another.
    static func claim() -> Bool {
        let center = DistributedNotificationCenter.default()
        if Background.isAgentProcess {
            if !others.isEmpty {
                center.postNotificationName(yield, object: nil, userInfo: nil, deliverImmediately: true)
            }
            return true
        }
        if !others.isEmpty, !Background.isTakeover {
            return false
        }
        return true
    }

    /// What a second copy does before it exits. macOS starts one whenever the
    /// app is opened again or sent a link, because it doesn't count the copy
    /// it keeps alive as the app already running. The second copy passes on
    /// whatever it was started for.
    static func handOver(links: [URL]) {
        let center = DistributedNotificationCenter.default()
        if links.isEmpty {
            center.postNotificationName(showSettings, object: nil, userInfo: nil, deliverImmediately: true)
        }
        for link in links {
            center.postNotificationName(openLink, object: link.absoluteString, userInfo: nil, deliverImmediately: true)
        }
    }

    static func listen(onShowSettings: @escaping () -> Void, onLink: @escaping (URL) -> Void) {
        let center = DistributedNotificationCenter.default()
        if !Background.isAgentProcess {
            center.addObserver(forName: yield, object: nil, queue: .main) { _ in
                Log.write("background: handing over to the copy macOS keeps alive")
                exit(0)
            }
        }
        center.addObserver(forName: showSettings, object: nil, queue: .main) { _ in onShowSettings() }
        center.addObserver(forName: openLink, object: nil, queue: .main) { note in
            guard let text = note.object as? String, let url = URL(string: text) else { return }
            onLink(url)
        }
    }
}

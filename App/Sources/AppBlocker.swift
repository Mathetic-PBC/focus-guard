import AppKit
import FocusGuardCore

/// Enforces app rules. An app on a block list is quit. Under an allow list,
/// an app that is not on it is hidden when it comes forward, and left running,
/// so nothing with unsaved work is closed just because a Focus went on.
@MainActor
final class AppBlocker {
    /// Never touched under an allow list: this app, and the two needed to see
    /// files and to change the settings that this app depends on.
    static let exempt: Set<String> = [
        Bundle.main.bundleIdentifier ?? "com.mathetic.FocusGuard",
        "com.apple.finder",
        "com.apple.systempreferences",
    ]

    private var policy: AppPolicy?
    /// Apps to quit on top of the profile's own list: browsers whose pages
    /// cannot be read while site rules are on.
    private var extra = Set<String>()
    private var observers: [NSObjectProtocol] = []
    private var startedAt = Date()
    private var closing = Set<pid_t>()

    func start(policy: AppPolicy, extra: Set<String>) {
        stop()
        self.policy = policy
        self.extra = extra
        startedAt = Date()
        guard policy.isActive || !extra.isEmpty else { return }
        observe()
        sweep()
    }

    func setExtra(_ extra: Set<String>) {
        guard let policy, extra != self.extra else { return }
        self.extra = extra
        if observers.isEmpty, policy.isActive || !extra.isEmpty { observe() }
        sweep()
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach(center.removeObserver)
        observers = []
        policy = nil
        extra = []
        closing = []
    }

    private func observe() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                Task { @MainActor in self?.enforce(app) }
            })
        }
    }

    private func sweep() {
        for app in NSWorkspace.shared.runningApplications { enforce(app) }
    }

    private func enforce(_ app: NSRunningApplication) {
        guard let policy, let bundleID = app.bundleIdentifier, !app.isTerminated,
              bundleID != Bundle.main.bundleIdentifier
        else { return }

        if extra.contains(bundleID) || (policy.mode == .block && policy.blocks(bundleID)) {
            quit(app, bundleID: bundleID)
        } else if policy.mode == .allow, app.activationPolicy == .regular, policy.blocks(bundleID), !app.isHidden {
            Log.write("apps: hid \(bundleID)")
            app.hide()
        }
    }

    /// Asks an app to quit, and keeps asking for a few seconds: an app that is
    /// still starting up drops the first request.
    ///
    /// What happens to one that will not go depends on when it was opened. An
    /// app opened during the session has nothing to lose and is forced. An app
    /// that was already open may be holding a "save changes?" sheet, so it is
    /// hidden instead, and asked again each time it comes forward.
    private func quit(_ app: NSRunningApplication, bundleID: String) {
        app.hide()
        guard closing.insert(app.processIdentifier).inserted else { return }
        Log.write("apps: quit \(bundleID)")
        let openedDuringSession = (app.launchDate ?? .distantPast) > startedAt
        app.terminate()
        for delay in [1.0, 2.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if !app.isTerminated { app.terminate() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            self?.closing.remove(app.processIdentifier)
            guard !app.isTerminated, self?.policy != nil else { return }
            if openedDuringSession {
                Log.write("apps: forced \(bundleID) to quit")
                app.forceTerminate()
            } else {
                Log.write("apps: \(bundleID) did not quit; hidden")
                app.hide()
            }
        }
    }
}

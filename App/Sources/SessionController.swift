import AppIntents
import AppKit
import Combine
import FocusGuardCore

/// What survives a restart: the session, and what has been learned about how
/// macOS reports Focus changes on this Mac.
private struct SavedState: Codable {
    var session: SessionState = .idle
    var suppressed: String?
    var lastSeen: [String: Date] = [:]
    var pollTrusted: Bool?
}

/// Joins the three parts: what macOS reports, the machine that decides, and
/// the blockers that act. Everything here runs on the main thread.
@MainActor
final class SessionController: ObservableObject {
    static let shared = SessionController()

    @Published var config: Config {
        didSet { if config != oldValue { saveConfig() } }
    }
    @Published private(set) var state: SessionState = .idle
    /// Advances once a second during a cool-down, to redraw the countdown.
    @Published private(set) var now = Date()
    /// When each profile was last switched on by a Focus. Empty for a profile
    /// means no Focus has been seen to drive it yet.
    @Published private(set) var lastSeen: [String: Date] = [:]
    @Published private(set) var shortcutNames: Set<String> = []
    @Published private(set) var deniedBrowsers: Set<String> = []

    private var machine: SessionMachine
    private var saved: SavedState
    private let web = WebBlocker()
    private let apps = AppBlocker()
    private let net = NetBlocker()
    private let panel = CooldownPanel()
    private var timer: Timer?
    private var ticks = 0

    // How Focus changes arrive. `perform()` on the filter is the event. A poll
    // of the filter's current value is the backstop for an event that was
    // missed, for example while the app was not running.
    private var epoch = 0
    private var calibration: (profile: String, at: Date)?
    private var pollInFlight = false
    private var quietPolls = 0
    private let startedAt = Date()
    private static let startupGrace: TimeInterval = 20

    private init() {
        config = ConfigStore.load(from: Paths.config)
        saved = (try? JSONDecoder().decode(SavedState.self, from: Data(contentsOf: Paths.state))) ?? SavedState()
        machine = SessionMachine(restoring: saved.session, suppressed: saved.suppressed)
        lastSeen = saved.lastSeen
    }

    var isLocked: Bool { state != .idle }

    /// True while the rules in force keep X out of reach. Drafts written in
    /// that time can't be posted until this goes false.
    var isXBlocked: Bool {
        state.profileID.flatMap(config.profile)?.sitePolicy.blocks("https://x.com/home") ?? false
    }

    /// Called when a session that blocked X ends, or gives way to one that
    /// doesn't.
    var onXUnblocked: (() -> Void)?

    var activeProfile: Profile? { state.profileID.flatMap(config.profile) }

    var remaining: TimeInterval? {
        if case .coolingDown(_, let until) = state { return until.timeIntervalSince(now) }
        return nil
    }

    private var environment: SessionEnvironment {
        let config = config
        let shortcuts = shortcutNames
        return SessionEnvironment(
            cooldown: { id in config.profile(id).map { TimeInterval($0.cooldownSeconds) } },
            canHold: { id in config.profile(id).map { shortcuts.contains(FocusHold.onName($0)) } ?? false })
    }

    // MARK: Start

    func start() {
        Log.write("start: pid \(getpid()), \(config.profiles.count) profile(s), restored \(machine.state)")
        web.onDeniedChange = { [weak self] denied in
            guard let self else { return }
            self.deniedBrowsers = denied
            self.apps.setExtra(self.closedBrowsers(denied: denied))
        }

        net.listen()
        if case .active(let id) = machine.state, config.profile(id) != nil {
            startBlocking(id)
        } else {
            machine = machine.state == .idle ? machine : SessionMachine()
            // A proxy setting left behind by a copy that was killed is removed.
            net.stop()
        }
        state = machine.state
        save()

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        refreshShortcuts()
        poll()

        #if DEBUG
        DebugHook.install(self)
        #endif
    }

    /// Called when the process is about to end, for any reason it can see
    /// coming. Blocking resumes from the saved session at the next start.
    func prepareToExit() {
        net.stopBeforeExit()
    }

    // MARK: What macOS reports

    /// Called by the Focus Filter when a connected Focus goes on (with its
    /// profile) or off (with none).
    func focusFilterPerformed(profileID: String?) {
        epoch += 1
        Log.write("focus: perform -> \(profileID ?? "none")")
        calibration = profileID.map { ($0, Date()) }
        report(profileID)
    }

    private func poll() {
        #if DEBUG
        // A test copy shares the installed copy's identity, so macOS would
        // answer it with the real Focus. A scripted run turns the question off.
        if ProcessInfo.processInfo.environment["FOCUSGUARD_NO_POLL"] == "1" { return }
        #endif
        guard !pollInFlight else { return }
        pollInFlight = true
        let asked = epoch
        Task {
            var value: String??
            do {
                value = .some(try await BlockingFocusFilter.current.profile?.id)
            } catch SetFocusFilterIntentError.notFound {
                value = .some(nil)
            } catch {
                Log.write("focus: poll failed: \(error)")
            }
            pollInFlight = false
            // A perform() that landed while this was in the air is newer.
            guard let value, asked == epoch else { return }
            pollAnswered(value)
        }
    }

    /// A poll that says "a profile is on" is believed. One that says "nothing
    /// is on" is believed only while polls have been seen to agree with events:
    /// if a poll says nothing is on just after an event said a Focus came on,
    /// polls on this Mac cannot be used to detect a Focus going off.
    private func pollAnswered(_ profile: String?) {
        if let check = calibration {
            guard Date().timeIntervalSince(check.at) >= 1.5 else { return }
            calibration = nil
            if profile == check.profile, saved.pollTrusted != true {
                saved.pollTrusted = true
                Log.write("focus: polls agree with events")
            } else if profile == nil, saved.pollTrusted != false {
                saved.pollTrusted = false
                Log.write("focus: polls disagree with events; relying on events alone")
            }
        }
        if profile == nil, saved.pollTrusted == false { return }
        // One "nothing is on" isn't believed while a session is running. macOS
        // gives that answer for a moment when it has lost track of the app's
        // filter, as it does just after an install, and acting on it would
        // start a cool-down nobody asked for. Two in a row are believed.
        if profile == nil {
            quietPolls += 1
            if machine.state != .idle, quietPolls < 2 { return }
            // Nor is it believed in the app's first seconds, when a session
            // carried over from before is most exposed to a wrong answer.
            if machine.state != .idle, Date().timeIntervalSince(startedAt) < Self.startupGrace { return }
        } else {
            quietPolls = 0
        }
        if !machine.hasObserved || machine.observed != profile {
            Log.write("focus: poll -> \(profile ?? "none")")
        }
        report(profile)
    }

    private func report(_ profile: String?) {
        if let profile, config.profile(profile) != nil {
            lastSeen[profile] = Date()
        }
        guard !machine.hasObserved || machine.observed != profile else { return }
        send(.observed(profile))
    }

    // MARK: What the person asks for

    func cancelCooldown() {
        send(.cancelCooldown)
    }

    func requestEnd() {
        send(.requestEnd)
    }

    // MARK: Machine

    private func tick() {
        ticks += 1
        send(.tick)
        if case .coolingDown = state { now = Date() }
        // Asked every second while a session runs, so that needing two
        // answers doesn't make switching the Focus off feel slow.
        if state != .idle || ticks % 3 == 0 { poll() }
        if ticks % 5 == 0 { net.verify() }
        if ticks % 300 == 0 { refreshShortcuts() }
    }

    private func send(_ event: SessionEvent) {
        let before = machine.state
        let effects = machine.handle(event, now: Date(), env: environment)
        if machine.state != before {
            Log.write("session: \(before) -> \(machine.state)")
        }
        for effect in effects { apply(effect) }
        if machine.state != state {
            let wasBlocked = isXBlocked
            state = machine.state
            now = Date()
            if wasBlocked, !isXBlocked { onXUnblocked?() }
        }
        if machine.state != before || !effects.isEmpty || event != .tick { save() }
    }

    private func apply(_ effect: SessionEffect) {
        switch effect {
        case .startBlocking(let id):
            startBlocking(id)
        case .stopBlocking:
            web.stop()
            apps.stop()
            net.stop()
            deniedBrowsers = []
        case .showCooldown(let id, let until):
            panel.show(profileName: config.profile(id)?.name ?? "Focus", until: until) { [weak self] in
                self?.cancelCooldown()
            }
        case .hideCooldown:
            panel.hide()
        case .holdFocus(let id):
            guard let profile = config.profile(id) else { return }
            Task { await FocusHold.runShortcut(FocusHold.onName(profile)) }
        case .releaseFocus(let id):
            guard let profile = config.profile(id), shortcutNames.contains(FocusHold.offName(profile)) else { return }
            Task { await FocusHold.runShortcut(FocusHold.offName(profile)) }
        }
    }

    private func startBlocking(_ id: String) {
        guard let profile = config.profile(id) else { return }
        refreshShortcuts()
        web.start(policy: profile.sitePolicy)
        net.start(policy: profile.sitePolicy)
        apps.start(policy: profile.appPolicy(exempt: AppBlocker.exempt), extra: closedBrowsers(denied: []))
    }

    /// Browsers whose pages cannot be checked are closed, but only while there
    /// are site rules to enforce.
    private func closedBrowsers(denied: Set<String>) -> Set<String> {
        guard let profile = machine.state.profileID.flatMap(config.profile), profile.sitePolicy.isActive
        else { return [] }
        return Browsers.unreadable.union(denied)
    }

    // MARK: Shortcuts

    func refreshShortcuts() {
        Task {
            let names = await FocusHold.list()
            if names != shortcutNames { shortcutNames = names }
        }
    }

    // MARK: Disk

    private func saveConfig() {
        do {
            try ConfigStore.save(config, to: Paths.config)
        } catch {
            Log.write("config: save failed: \(error)")
        }
    }

    private func save() {
        saved.session = machine.state
        saved.suppressed = machine.suppressed
        saved.lastSeen = lastSeen
        do {
            try FileManager.default.createDirectory(at: Paths.home, withIntermediateDirectories: true)
            try JSONEncoder().encode(saved).write(to: Paths.state, options: .atomic)
        } catch {
            Log.write("state: save failed: \(error)")
        }
    }
}

#if DEBUG
extension SessionController {
    func debugDragPanel(by offset: NSSize, onButton: Bool) { panel.debugDrag(by: offset, onButton: onButton) }
}

/// Stands in for macOS switching a Focus, so a build can be exercised without
/// touching the real Focus settings. Compiled out of release builds, where it
/// would be a way around the cool-down.
enum DebugHook {
    static let name = Notification.Name("com.mathetic.FocusGuard.debug")

    @MainActor
    static func install(_ controller: SessionController) {
        DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: .main) { note in
            let command = note.object as? String ?? ""
            Task { @MainActor in
                Log.write("debug: \(command)")
                if command.hasPrefix("on:") {
                    let wanted = String(command.dropFirst(3))
                    let id = controller.config.profiles.first { $0.name == wanted }?.id
                    controller.focusFilterPerformed(profileID: id ?? wanted)
                } else if command == "off" {
                    controller.focusFilterPerformed(profileID: nil)
                } else if command == "stay" {
                    controller.cancelCooldown()
                } else if command == "end" {
                    controller.requestEnd()
                } else if command.hasPrefix("snapshot:") {
                    AppDelegate.snapshotSettings(to: String(command.dropFirst(9)))
                } else if command.hasPrefix("snapshot-drafts:") {
                    AppDelegate.snapshotDrafts(to: String(command.dropFirst(16)))
                } else if command.hasPrefix("panel-drag:") || command.hasPrefix("panel-press:") {
                    // "panel-drag:dx,dy" drags by the body. "panel-press:dx,dy" does the same on the button.
                    let parts = command.split(separator: ":")[1].split(separator: ",").compactMap { Double($0) }
                    if parts.count == 2 {
                        controller.debugDragPanel(
                            by: NSSize(width: parts[0], height: parts[1]), onButton: command.hasPrefix("panel-press:"))
                    }
                } else if command.hasPrefix("compose-") || command.hasPrefix("people-") {
                    DraftsDebug.run(command)
                } else if command == "drafts" {
                    AppDelegate.showDrafts(reviewing: false)
                }
            }
        }
    }
}
#endif

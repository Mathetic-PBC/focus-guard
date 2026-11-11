import Foundation

public enum SessionState: Codable, Equatable, Sendable {
    /// Nothing is blocked.
    case idle
    /// A profile's rules are in force.
    case active(profileID: String)
    /// The Focus was switched off. Rules stay in force until `until`, unless cancelled.
    case coolingDown(profileID: String, until: Date)

    public var profileID: String? {
        switch self {
        case .idle: return nil
        case .active(let id), .coolingDown(let id, _): return id
        }
    }
}

public enum SessionEvent: Equatable, Sendable {
    /// What macOS says right now: the profile whose Focus is on, or nil for none.
    case observed(String?)
    case tick
    /// "Stay focused", pressed during a cool-down.
    case cancelCooldown
    /// "End session", chosen from the menu while the Focus is still on.
    case requestEnd
}

public enum SessionEffect: Equatable, Sendable {
    case startBlocking(String)
    case stopBlocking
    case showCooldown(profileID: String, until: Date)
    case hideCooldown
    /// Switch the system Focus back on, so it stays on through the cool-down.
    case holdFocus(String)
    /// Switch the system Focus off, now that the cool-down has run out.
    case releaseFocus(String)
}

public struct SessionEnvironment {
    /// The cool-down for a profile, or nil when the profile no longer exists.
    public var cooldown: (String) -> TimeInterval?
    /// Whether the system Focus for a profile can be switched on from here.
    public var canHold: (String) -> Bool

    public init(cooldown: @escaping (String) -> TimeInterval?, canHold: @escaping (String) -> Bool) {
        self.cooldown = cooldown
        self.canHold = canHold
    }
}

/// Decides when rules are in force. Holds no timers and touches nothing outside
/// itself: it takes events and a clock reading, and returns what should happen.
///
/// The rule it exists for: switching a Focus off never ends blocking at once.
/// It starts a cool-down, and blocking ends only when that runs out.
public struct SessionMachine: Equatable, Sendable {
    /// How long after asking for the Focus to be switched back on its return is
    /// taken to be our doing and not the person's.
    public static let holdWindow: TimeInterval = 15

    public private(set) var state: SessionState
    /// The last thing macOS reported, once it has reported anything.
    public private(set) var observed: String?
    public private(set) var hasObserved = false
    /// A profile whose session ended while its Focus was still on. It is ignored
    /// until the Focus is seen off, so ending a session cannot restart it.
    public private(set) var suppressed: String?
    private var holdRequestedAt: Date?

    public init() {
        state = .idle
    }

    /// Picks up after a restart. A cool-down that was running is not resumed:
    /// the session returns to active, and a fresh cool-down starts if the Focus
    /// turns out to be off. Quitting the app therefore cannot shorten the wait.
    public init(restoring saved: SessionState, suppressed: String?) {
        switch saved {
        case .idle: state = .idle
        case .active(let id), .coolingDown(let id, _): state = .active(profileID: id)
        }
        self.suppressed = suppressed
    }

    public mutating func handle(_ event: SessionEvent, now: Date, env: SessionEnvironment) -> [SessionEffect] {
        switch event {
        case .observed(let profile): return observe(profile, now: now, env: env)
        case .tick: return tick(now: now, env: env)
        case .cancelCooldown: return cancel(now: now, env: env)
        case .requestEnd: return requestEnd(now: now, env: env)
        }
    }

    private func eligible(_ profile: String?, env: SessionEnvironment) -> String? {
        guard let profile, profile != suppressed, env.cooldown(profile) != nil else { return nil }
        return profile
    }

    private mutating func observe(_ profile: String?, now: Date, env: SessionEnvironment) -> [SessionEffect] {
        hasObserved = true
        observed = profile
        if suppressed != nil, suppressed != profile { suppressed = nil }

        switch state {
        case .idle:
            guard let next = eligible(profile, env: env) else { return [] }
            state = .active(profileID: next)
            return [.startBlocking(next)]

        case .active(let current):
            if profile == current {
                holdRequestedAt = nil
                return []
            }
            guard let cooldown = env.cooldown(current) else {
                return endSession(env: env)
            }
            let until = now.addingTimeInterval(cooldown)
            state = .coolingDown(profileID: current, until: until)
            var effects: [SessionEffect] = [.showCooldown(profileID: current, until: until)]
            if env.canHold(current) {
                holdRequestedAt = now
                effects.append(.holdFocus(current))
            }
            return effects

        case .coolingDown(let current, _):
            if profile == current {
                if holdRequestedAt != nil {
                    // The Focus came back because we asked. The cool-down runs on.
                    holdRequestedAt = nil
                    return []
                }
                // The person switched it back on. That is a change of mind.
                state = .active(profileID: current)
                return [.hideCooldown]
            }
            if holdRequestedAt == nil, env.canHold(current) {
                holdRequestedAt = now
                return [.holdFocus(current)]
            }
            return []
        }
    }

    private mutating func tick(now: Date, env: SessionEnvironment) -> [SessionEffect] {
        if let asked = holdRequestedAt, now.timeIntervalSince(asked) > Self.holdWindow {
            holdRequestedAt = nil
        }
        guard case .coolingDown(let current, let until) = state, now >= until else { return [] }
        holdRequestedAt = nil

        if observed == current {
            suppressed = current
            state = .idle
            return [.hideCooldown, .stopBlocking, .releaseFocus(current)]
        }
        return [.hideCooldown] + endSession(env: env)
    }

    /// Ends the current session and, if another connected Focus is on, starts its.
    private mutating func endSession(env: SessionEnvironment) -> [SessionEffect] {
        if let next = eligible(observed, env: env), next != state.profileID {
            state = .active(profileID: next)
            return [.startBlocking(next)]
        }
        state = .idle
        return [.stopBlocking]
    }

    private mutating func cancel(now: Date, env: SessionEnvironment) -> [SessionEffect] {
        guard case .coolingDown(let current, _) = state else { return [] }
        state = .active(profileID: current)
        var effects: [SessionEffect] = [.hideCooldown]
        if observed != current, env.canHold(current) {
            holdRequestedAt = now
            effects.append(.holdFocus(current))
        } else {
            holdRequestedAt = nil
        }
        return effects
    }

    private mutating func requestEnd(now: Date, env: SessionEnvironment) -> [SessionEffect] {
        guard case .active(let current) = state else { return [] }
        guard let cooldown = env.cooldown(current) else { return endSession(env: env) }
        let until = now.addingTimeInterval(cooldown)
        state = .coolingDown(profileID: current, until: until)
        return [.showCooldown(profileID: current, until: until)]
    }
}

import Foundation

enum Paths {
    /// Everything the app writes lives here. FOCUSGUARD_HOME moves it, which is
    /// how a test run keeps away from the real rules.
    static let home: URL = {
        if let override = ProcessInfo.processInfo.environment["FOCUSGUARD_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("FocusGuard", isDirectory: true)
    }()

    static let isOverridden = ProcessInfo.processInfo.environment["FOCUSGUARD_HOME"]?.isEmpty == false

    static var config: URL { home.appendingPathComponent("config.json") }
    static var state: URL { home.appendingPathComponent("state.json") }
    static var blockPage: URL { home.appendingPathComponent("blocked.html") }
    static var log: URL { home.appendingPathComponent("focusguard.log") }
    static var drafts: URL { home.appendingPathComponent("drafts.json") }
}

/// A plain text log of what was seen and what was done about it. It is the
/// only way to tell, after the fact, why a session started or ended.
enum Log {
    private static let queue = DispatchQueue(label: "com.mathetic.FocusGuard.log")
    private static let limit = 512 * 1024
    private static let stamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func write(_ message: String) {
        let line = "\(stamp.string(from: Date())) \(message)\n"
        queue.async {
            let url = Paths.log
            let manager = FileManager.default
            try? manager.createDirectory(at: Paths.home, withIntermediateDirectories: true)
            if let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? Int, size > limit {
                try? manager.removeItem(at: url)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}

func formatCountdown(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.rounded(.up)))
    return String(format: "%d:%02d", total / 60, total % 60)
}

func formatDuration(_ seconds: Int) -> String {
    if seconds < 60 { return "\(seconds) seconds" }
    let minutes = seconds / 60
    let rest = seconds % 60
    let head = minutes == 1 ? "1 minute" : "\(minutes) minutes"
    return rest == 0 ? head : "\(head) \(rest) seconds"
}

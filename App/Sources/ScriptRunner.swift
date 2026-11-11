import Foundation

struct ScriptError: Error {
    static let notPermitted = -1743
    static let needsConsent = -1744

    let code: Int
    let message: String
}

/// Runs AppleScript on one thread of its own. A browser that is slow to answer,
/// or a permission prompt waiting for a click, then holds up this thread and
/// nothing else.
final class ScriptRunner {
    private let condition = NSCondition()
    private var pending: [() -> Void] = []
    private var compiled: [String: NSAppleScript] = [:]

    init() {
        let thread = Thread { [weak self] in self?.loop() }
        thread.name = "com.mathetic.FocusGuard.scripts"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private func loop() {
        while true {
            condition.lock()
            while pending.isEmpty { condition.wait() }
            let work = pending.removeFirst()
            condition.unlock()
            autoreleasepool { work() }
        }
    }

    /// `cacheKey` keeps the compiled script for sources that never change.
    func run(_ source: String, cacheKey: String? = nil, completion: @escaping (Result<String, ScriptError>) -> Void) {
        condition.lock()
        pending.append { [self] in
            let result = execute(source, cacheKey: cacheKey)
            DispatchQueue.main.async { completion(result) }
        }
        condition.signal()
        condition.unlock()
    }

    private func execute(_ source: String, cacheKey: String?) -> Result<String, ScriptError> {
        let script: NSAppleScript
        if let cacheKey, let cached = compiled[cacheKey] {
            script = cached
        } else {
            guard let fresh = NSAppleScript(source: source) else {
                return .failure(ScriptError(code: 0, message: "could not read script"))
            }
            script = fresh
            if let cacheKey { compiled[cacheKey] = fresh }
        }
        var error: NSDictionary?
        let output = script.executeAndReturnError(&error)
        if let error {
            return .failure(ScriptError(
                code: error[NSAppleScript.errorNumber] as? Int ?? 0,
                message: error[NSAppleScript.errorMessage] as? String ?? "unknown error"))
        }
        return .success(output.stringValue ?? "")
    }
}

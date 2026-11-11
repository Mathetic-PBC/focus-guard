import AppKit

/// What is known about the browsers on this Mac, and the AppleScript each
/// family answers to. A browser is "readable" when it will tell another app
/// which pages it has open and accept a new address for a tab.
enum Browsers {
    enum Family {
        case chromium
        case safari
    }

    static let readable: [String: Family] = [
        "com.google.Chrome": .chromium,
        "com.google.Chrome.beta": .chromium,
        "com.google.Chrome.dev": .chromium,
        "com.google.Chrome.canary": .chromium,
        "org.chromium.Chromium": .chromium,
        "com.brave.Browser": .chromium,
        "com.brave.Browser.beta": .chromium,
        "com.microsoft.edgemac": .chromium,
        "com.vivaldi.Vivaldi": .chromium,
        "com.operasoftware.Opera": .chromium,
        "com.apple.Safari": .safari,
        "com.apple.SafariTechnologyPreview": .safari,
    ]

    /// Browsers that will not report their pages. While site rules are in
    /// force these are closed, because nothing else can be done about them.
    static let unreadable: Set<String> = [
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.nightly",
        "app.zen-browser.zen",
        "io.gitlab.librewolf-community",
        "org.torproject.torbrowser",
        "com.duckduckgo.macos.browser",
        "com.kagi.kagimacOS",
        "company.thebrowser.Browser",
        "com.openai.atlas",
        "company.thebrowser.dia",
        "ai.perplexity.comet",
    ]

    struct Installed: Identifiable {
        let bundleID: String
        let name: String
        let url: URL
        var id: String { bundleID }
    }

    static func installedReadable() -> [Installed] {
        readable.keys.sorted().compactMap { bundleID in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
            return Installed(bundleID: bundleID, name: FileManager.default.displayName(atPath: url.path), url: url)
        }
    }

    static func installedUnreadable() -> [Installed] {
        unreadable.sorted().compactMap { bundleID in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
            return Installed(bundleID: bundleID, name: FileManager.default.displayName(atPath: url.path), url: url)
        }
    }

    static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    // Each script returns one line per tab: window id, tab reference, address.
    // The separators are built outside the `tell` block, where `tab` still
    // means the character and not the browser's own class.

    static func listScript(bundleID: String, family: Family, allTabs: Bool) -> String {
        let body: String
        switch (family, allTabs) {
        case (.chromium, false):
            body = """
                repeat with w in windows
                  try
                    set t to active tab of w
                    set u to URL of t
                    if u is not missing value then set out to out & (id of w) & sep & (id of t) & sep & u & nl
                  end try
                end repeat
                """
        case (.chromium, true):
            body = """
                repeat with w in windows
                  repeat with t in tabs of w
                    try
                      set u to URL of t
                      if u is not missing value then set out to out & (id of w) & sep & (id of t) & sep & u & nl
                    end try
                  end repeat
                end repeat
                """
        case (.safari, false):
            body = """
                repeat with w in windows
                  try
                    set t to current tab of w
                    set u to URL of t
                    if u is not missing value then set out to out & (id of w) & sep & (index of t) & sep & u & nl
                  end try
                end repeat
                """
        case (.safari, true):
            body = """
                repeat with w in windows
                  repeat with t in tabs of w
                    try
                      set u to URL of t
                      if u is not missing value then set out to out & (id of w) & sep & (index of t) & sep & u & nl
                    end try
                  end repeat
                end repeat
                """
        }
        return """
            set sep to character id 9
            set nl to character id 10
            set out to ""
            with timeout of 4 seconds
              tell application id "\(bundleID)"
            \(body)
              end tell
            end timeout
            return out
            """
    }

    static func redirectScript(bundleID: String, family: Family, window: Int, tab: Int, to address: String) -> String {
        let target: String
        switch family {
        case .chromium: target = "(first tab of (first window whose id is \(window)) whose id is \(tab))"
        case .safari: target = "tab \(tab) of (first window whose id is \(window))"
        }
        let quoted = address.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return """
            with timeout of 4 seconds
              tell application id "\(bundleID)" to set URL of \(target) to "\(quoted)"
            end timeout
            """
    }

    /// Asks macOS whether this app may send events to a browser. With `ask`,
    /// macOS shows its permission prompt if the question has never been put.
    static func permission(for bundleID: String, ask: Bool) -> Permission {
        guard isRunning(bundleID) else { return .notRunning }
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let descriptor = target.aeDesc else { return .unknown(0) }
        let status = AEDeterminePermissionToAutomateTarget(descriptor, typeWildCard, typeWildCard, ask)
        switch Int(status) {
        case 0: return .granted
        case ScriptError.notPermitted: return .denied
        case ScriptError.needsConsent: return .notAsked
        case -600: return .notRunning
        default: return .unknown(Int(status))
        }
    }

    enum Permission: Equatable {
        case granted
        case denied
        case notAsked
        case notRunning
        case unknown(Int)
    }
}

import AppKit
import FocusGuardCore

/// Enforces site rules by asking each running browser which pages it is
/// showing and sending any blocked one to a local page that says so.
///
/// A page can be on screen for up to one check interval before it is replaced.
@MainActor
final class WebBlocker {
    static let interval: TimeInterval = 0.75

    /// Browsers that refused to be read. The owner closes them, since their
    /// pages cannot be checked.
    var onDeniedChange: ((Set<String>) -> Void)?
    private(set) var denied = Set<String>() {
        didSet { if denied != oldValue { onDeniedChange?(denied) } }
    }

    private let runner = ScriptRunner()
    private var policy: SitePolicy?
    private var timer: Timer?
    private var ticks = 0
    private var inFlight = Set<String>()

    var isRunning: Bool { policy != nil }

    func start(policy: SitePolicy) {
        stop()
        guard policy.isActive else { return }
        self.policy = policy
        BlockPage.install()
        ticks = 0
        for bundleID in Browsers.readable.keys where Browsers.isRunning(bundleID) {
            check(bundleID, allTabs: true)
        }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        policy = nil
        denied = []
    }

    private func tick() {
        ticks += 1
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        // The browser in front is checked every time. The others, which may be
        // showing on another display, every fourth. Background tabs are swept
        // about twice a minute.
        let everyBrowser = ticks % 4 == 0
        let allTabs = ticks % 40 == 0
        for bundleID in Browsers.readable.keys {
            guard bundleID == front || everyBrowser, Browsers.isRunning(bundleID) else { continue }
            check(bundleID, allTabs: allTabs)
        }
    }

    private func check(_ bundleID: String, allTabs: Bool) {
        guard let family = Browsers.readable[bundleID], !inFlight.contains(bundleID) else { return }
        inFlight.insert(bundleID)
        let source = Browsers.listScript(bundleID: bundleID, family: family, allTabs: allTabs)
        runner.run(source, cacheKey: "\(bundleID)|\(allTabs)") { [weak self] result in
            guard let self else { return }
            self.inFlight.remove(bundleID)
            guard let policy = self.policy else { return }
            switch result {
            case .success(let output):
                self.denied.remove(bundleID)
                self.judge(output, bundleID: bundleID, family: family, policy: policy)
            case .failure(let error):
                if error.code == ScriptError.notPermitted {
                    if self.denied.insert(bundleID).inserted {
                        Log.write("web: not allowed to read \(bundleID); it will be closed while site rules are on")
                    }
                } else if error.code != -600, error.code != -609 {
                    Log.write("web: \(bundleID) error \(error.code): \(error.message)")
                }
            }
        }
    }

    private func judge(_ output: String, bundleID: String, family: Browsers.Family, policy: SitePolicy) {
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3, let window = Int(fields[0]), let tab = Int(fields[1]) else { continue }
            let address = String(fields[2])
            guard policy.blocks(address) else { continue }
            let host = URLComponents(string: address)?.host ?? address
            Log.write("web: blocked \(host) in \(bundleID)")
            let redirect = Browsers.redirectScript(
                bundleID: bundleID, family: family, window: window, tab: tab,
                to: BlockPage.address(for: host))
            runner.run(redirect) { result in
                if case .failure(let error) = result {
                    Log.write("web: could not replace tab in \(bundleID): \(error.code) \(error.message)")
                }
            }
        }
    }
}

/// The page a blocked tab is sent to. It is a file on disk, so it loads with
/// no network and is never itself judged by the rules.
enum BlockPage {
    static func address(for host: String) -> String {
        var components = URLComponents(url: Paths.blockPage, resolvingAgainstBaseURL: false)!
        components.fragment = host
        return components.string ?? Paths.blockPage.absoluteString
    }

    static func install() {
        try? FileManager.default.createDirectory(at: Paths.home, withIntermediateDirectories: true)
        try? Data(html.utf8).write(to: Paths.blockPage, options: .atomic)
    }

    private static let html = """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Blocked</title>
        <style>
          :root { color-scheme: light dark; --ink: #1d1d1f; --soft: #6e6e73; --paper: #f5f5f7; }
          @media (prefers-color-scheme: dark) { :root { --ink: #f5f5f7; --soft: #a1a1a6; --paper: #161617; } }
          html, body { height: 100%; margin: 0; }
          body { display: grid; place-items: center; background: var(--paper); color: var(--ink);
                 font: 17px/1.5 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; }
          main { max-width: 30rem; padding: 2rem; text-align: center; }
          h1 { font-size: 1.75rem; font-weight: 600; letter-spacing: -0.01em; margin: 0 0 .5rem; text-wrap: balance; }
          p { color: var(--soft); margin: 0; text-wrap: pretty; }
          code { font: inherit; color: var(--ink); overflow-wrap: anywhere; }
          #draft { margin-top: 1.25rem; }
          a { color: #0a66d8; text-decoration: none; font-weight: 500; }
          a:hover { text-decoration: underline; }
          @media (prefers-color-scheme: dark) { a { color: #4aa3ff; } }
        </style>
        </head>
        <body>
        <main>
          <h1 id="title">This site is blocked</h1>
          <p>Your Focus is on. To open it, switch the Focus off and wait out the cool-down.</p>
          <p id="draft" hidden><a href="focusguard://drafts">Write a draft to post later</a></p>
        </main>
        <script>
          const host = decodeURIComponent(location.hash.slice(1));
          if (host) {
            const title = document.getElementById("title");
            const name = document.createElement("code");
            name.textContent = host;
            title.textContent = "";
            title.append(name, " is blocked");
            if (/(^|\\.)(x|twitter)\\.com$/.test(host)) document.getElementById("draft").hidden = false;
          }
        </script>
        </body>
        </html>
        """
}

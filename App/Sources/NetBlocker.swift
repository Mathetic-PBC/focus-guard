import Foundation
import FocusGuardCore
import Network
import Security
import SystemConfiguration

/// Blocks sites below the browser, for pages that live inside other apps: the
/// built-in browsers of Claude, Codex, Engelbart and the like, which have no
/// tabs that can be read from outside.
///
/// During a session macOS is given a proxy auto-config file. Apps that follow
/// the system proxy settings, which web views do, run it for every request. It
/// sends requests for blocked hosts to a listener in this app, which refuses
/// them, and leaves every other request alone.
///
/// The file is served by this app, so the setting is only safe while the app
/// is running. What happens if the app is gone and the setting is still on
/// depends on `DirectFallback`: by default apps connect directly, as if there
/// were no proxy. With direct fallback off, Apple's networking reports every
/// site as offline until the app is back or the setting is switched off. The
/// app is restarted within a second when it dies, and takes the setting down
/// itself whenever it is asked to stop.
@MainActor
final class NetBlocker {
    static let port: UInt16 = {
        ProcessInfo.processInfo.environment["FOCUSGUARD_PORT"].flatMap(UInt16.init) ?? 47113
    }()
    private static var address: String { "127.0.0.1:\(port)" }
    private static var base: String { "http://\(address)/proxy.pac" }

    private let proxy = LocalProxy(port: NetBlocker.port)
    /// The address macOS should be pointing at, while a session wants it to.
    private var wanted: String?

    func listen() {
        proxy.start()
    }

    func start(policy: SitePolicy) {
        let hosts = policy.networkHosts
        guard !hosts.isEmpty else {
            stop()
            return
        }
        proxy.setRules(
            pac: ProxyAutoConfig.source(blocking: hosts, via: Self.address),
            hosts: hosts)
        // The address changes with the list, so apps fetch the file again
        // instead of trusting a copy made under other rules.
        var hash: UInt64 = 5381
        for byte in hosts.joined(separator: ",").utf8 { hash = hash &* 33 &+ UInt64(byte) }
        let address = "\(Self.base)?v=\(String(hash, radix: 36))"
        wanted = address
        Log.write("net: refusing \(hosts.count) host(s) system-wide")
        SystemProxy.point(at: address)
    }

    func stop() {
        wanted = nil
        proxy.setRules(pac: ProxyAutoConfig.source(blocking: [], via: Self.address), hosts: [])
        SystemProxy.release(prefix: Self.base)
    }

    /// Takes the setting down before the process ends, and waits for that.
    func stopBeforeExit() {
        wanted = nil
        SystemProxy.releaseNow(prefix: Self.base)
    }

    /// Puts the setting back if it was switched off in System Settings.
    func verify() {
        guard let wanted, !SystemProxy.isInForce(wanted) else { return }
        Log.write("net: proxy setting is not in force; setting it")
        SystemProxy.point(at: wanted)
    }
}

/// The system-wide proxy auto-config setting. macOS keeps one per network
/// service, so each enabled service is set.
///
/// Switching the setting on and off goes through `networksetup`, which macOS
/// lets an administrator run without a password. Nothing in a session ever
/// asks for one.
enum SystemProxy {
    private static let queue = DispatchQueue(label: "com.mathetic.FocusGuard.systemproxy")
    private static let tool = "/usr/sbin/networksetup"

    static func point(at address: String) {
        queue.async {
            for service in services() {
                let current = setting(for: service)
                // A proxy file someone else configured is theirs. It is left
                // alone, and the log says the block is not in force there.
                if current.enabled, let url = current.url, !url.hasPrefix("http://127.0.0.1:") {
                    Log.write("net: \(service) already uses \(url); left as it is")
                    continue
                }
                if current.enabled, current.url == address { continue }
                let status = run(["-setautoproxyurl", service, address]).status
                if status != 0 { Log.write("net: could not set proxy on \(service) (\(status))") }
            }
        }
    }

    /// Switches the setting off wherever it points at this app.
    static func release(prefix: String) {
        queue.async {
            for service in services() {
                let current = setting(for: service)
                guard current.enabled, let url = current.url, url.hasPrefix(prefix) else { continue }
                _ = run(["-setautoproxystate", service, "off"])
            }
        }
    }

    static func releaseNow(prefix: String) {
        release(prefix: prefix)
        queue.sync {}
    }

    /// True when macOS is pointing at `address`.
    static func isInForce(_ address: String) -> Bool {
        let settings = SCDynamicStoreCopyProxies(nil) as? [String: Any] ?? [:]
        return (settings["ProxyAutoConfigEnable"] as? Int) == 1
            && (settings["ProxyAutoConfigURLString"] as? String) == address
    }

    private static func services() -> [String] {
        guard let output = run(["-listallnetworkservices"]).output else { return [] }
        // The first line is a note about the asterisk that marks disabled services.
        return output.split(separator: "\n").dropFirst().map(String.init).filter { !$0.hasPrefix("*") }
    }

    private static func setting(for service: String) -> (url: String?, enabled: Bool) {
        guard let output = run(["-getautoproxyurl", service]).output else { return (nil, false) }
        var url: String?
        var enabled = false
        for line in output.split(separator: "\n") {
            if line.hasPrefix("URL: ") {
                let value = String(line.dropFirst(5))
                url = value == "(null)" ? nil : value
            } else if line.hasPrefix("Enabled: ") {
                enabled = line.dropFirst(9) == "Yes"
            }
        }
        return (url, enabled)
    }

    private static func run(_ arguments: [String]) -> (status: Int32, output: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (-1, nil)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8))
    }
}

/// The one network setting that takes a password to change.
///
/// When a proxy refuses a request, Chromium gives up, so apps built on it are
/// blocked with no further setup. Apple's networking, which WebKit-based apps
/// use, instead treats the proxy as broken and connects directly, unless
/// "fall back to a direct connection" is off for the network service.
///
/// `networksetup` has no switch for that, and writing it directly makes macOS
/// ask for an administrator password. So it is changed only when the person
/// presses the button for it, once, and stays as set. With no proxy in use
/// the value does nothing.
///
/// The cost: with fallback off, a proxy file that can't be fetched no longer
/// means "connect directly". It means "offline", for every site, in every app
/// that uses Apple's networking. See `NetBlocker` for how that is contained.
enum DirectFallback {
    private static let key = "FallBackAllowed"

    /// True when every enabled network service has direct fallback off.
    static var isOff: Bool {
        guard let preferences = SCPreferencesCreate(nil, "com.mathetic.FocusGuard" as CFString, nil) else { return false }
        let settings = proxySettings(in: preferences)
        return !settings.isEmpty && settings.allSatisfy { ($0.values[key] as? Int) == 0 }
    }

    /// Makes one change to all services, so macOS asks for the password once.
    /// Call this only in answer to a click.
    static func set(off: Bool) -> Bool {
        var authorization: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &authorization) == errAuthorizationSuccess, let authorization,
              let preferences = SCPreferencesCreateWithAuthorization(
                nil, "com.mathetic.FocusGuard" as CFString, nil, authorization)
        else { return false }
        defer { AuthorizationFree(authorization, []) }
        guard SCPreferencesLock(preferences, true) else {
            Log.write("net: network settings were not unlocked")
            return false
        }
        defer { SCPreferencesUnlock(preferences) }

        for entry in proxySettings(in: preferences) {
            var values = entry.values
            if off { values[key] = 0 } else { values.removeValue(forKey: key) }
            SCNetworkProtocolSetConfiguration(entry.proxies, values as CFDictionary)
        }
        let saved = SCPreferencesCommitChanges(preferences) && SCPreferencesApplyChanges(preferences)
        Log.write("net: direct fallback \(off ? "off" : "restored"): \(saved ? "saved" : "not saved")")
        return saved
    }

    private static func proxySettings(in preferences: SCPreferences) -> [(proxies: SCNetworkProtocol, values: [String: Any])] {
        (SCNetworkServiceCopyAll(preferences) as? [SCNetworkService] ?? []).compactMap { service in
            guard SCNetworkServiceGetEnabled(service),
                  let proxies = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies)
            else { return nil }
            return (proxies, SCNetworkProtocolGetConfiguration(proxies) as? [String: Any] ?? [:])
        }
    }
}

/// Answers on one local port, for two kinds of caller: an app fetching the
/// proxy auto-config file, and an app that ran the file and was sent here
/// with a request for a blocked host. The second kind is always refused.
final class LocalProxy {
    private let port: UInt16
    private let queue = DispatchQueue(label: "com.mathetic.FocusGuard.proxy")
    private var listener: NWListener?
    private var pac = ProxyAutoConfig.source(blocking: [], via: "127.0.0.1:0")
    private var hosts: [String] = []
    private var lastLogged: [String: Date] = [:]

    init(port: UInt16) {
        self.port = port
    }

    func setRules(pac: String, hosts: [String]) {
        queue.async {
            self.pac = pac
            self.hosts = hosts
        }
    }

    func start() {
        queue.async { [self] in
            guard listener == nil, let endpointPort = NWEndpoint.Port(rawValue: port) else { return }
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            // Loopback only. Nothing off this Mac can reach the listener.
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: endpointPort)
            do {
                let listener = try NWListener(using: parameters)
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.stateUpdateHandler = { state in
                    if case .failed(let error) = state {
                        Log.write("net: listener failed: \(error)")
                    }
                }
                listener.start(queue: queue)
                self.listener = listener
            } catch {
                Log.write("net: could not listen on port \(port): \(error)")
            }
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, collected: Data())
    }

    private func read(_ connection: NWConnection, collected: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, error in
            guard let self else { return }
            var collected = collected
            if let data { collected.append(data) }
            let headEnd = collected.range(of: Data("\r\n\r\n".utf8))
            if headEnd == nil, error == nil, !done, collected.count < 32768 {
                self.read(connection, collected: collected)
                return
            }
            self.respond(connection, head: String(decoding: collected, as: UTF8.self))
        }
    }

    private func respond(_ connection: NWConnection, head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2 else {
            connection.cancel()
            return
        }
        let method = String(parts[0])
        let target = String(parts[1])

        let response: Data
        if method == "GET", target.hasPrefix("/proxy.pac") {
            response = reply(
                status: "200 OK", type: "application/x-ns-proxy-autoconfig",
                extra: "Cache-Control: no-store\r\n", body: Data(pac.utf8))
        } else if method == "CONNECT" {
            note(host: target.split(separator: ":").first.map(String.init) ?? target, head: lines)
            // The tunnel is granted, and closed as soon as the app starts to
            // speak through it. The app sees a secure connection that failed,
            // which reads as "this site is down" and never as a request for a
            // proxy password, which a refusal with an error code can become.
            let granted = Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)
            connection.send(content: granted, completion: .contentProcessed { _ in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
                    connection.cancel()
                }
            })
            return
        } else if let host = URLComponents(string: target)?.host {
            note(host: host, head: lines)
            response = reply(
                status: "403 Forbidden", type: "text/html; charset=utf-8", extra: "",
                body: Data("<!doctype html><meta charset=utf-8><title>Blocked</title><body style=\"font:17px -apple-system;display:grid;place-items:center;height:100vh;margin:0\"><p><b>\(host)</b> is blocked while your Focus is on.</p>".utf8))
        } else {
            response = reply(status: "404 Not Found", type: "text/plain", extra: "", body: Data())
        }
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func reply(status: String, type: String, extra: String, body: Data) -> Data {
        var data = Data(
            "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n\(extra)Connection: close\r\n\r\n".utf8)
        data.append(body)
        return data
    }

    /// One log line per host and app per minute. A page that keeps retrying
    /// would otherwise fill the log.
    private func note(host: String, head: [String]) {
        let agent = head.first { $0.lowercased().hasPrefix("user-agent:") }
            .map { String($0.dropFirst(11)).trimmingCharacters(in: .whitespaces) } ?? "unknown app"
        let app = Self.appName(fromAgent: agent)
        let key = "\(host)|\(app)"
        let now = Date()
        if let last = lastLogged[key], now.timeIntervalSince(last) < 60 { return }
        lastLogged[key] = now
        if lastLogged.count > 500 { lastLogged.removeAll() }
        Log.write("net: refused \(host) for \(app)")
    }

    /// Picks the app's own name out of a browser-style identification string,
    /// which lists it among the engines it is built on.
    static func appName(fromAgent agent: String) -> String {
        let engines: Set<String> = ["Mozilla", "AppleWebKit", "Chrome", "Safari", "Electron", "Version", "Mobile", "Gecko"]
        let products = agent.split(separator: " ").compactMap { token -> String? in
            guard let slash = token.firstIndex(of: "/"), !token.hasPrefix("(") else { return nil }
            return String(token[..<slash])
        }
        return products.first { !engines.contains($0) } ?? products.last ?? agent
    }
}

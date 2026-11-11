import Foundation

/// One line of a site list: a host, and optionally a path under it.
/// "x.com" covers x.com and every subdomain. "linkedin.com/feed" covers only
/// that path and what is below it.
public struct SiteRule: Equatable, Hashable, Sendable {
    public let host: String
    public let path: String

    public init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let scheme = text.range(of: "://") { text = String(text[scheme.upperBound...]) }
        if let cut = text.firstIndex(where: { $0 == "?" || $0 == "#" }) { text = String(text[..<cut]) }

        var host = text
        var path = ""
        if let slash = text.firstIndex(of: "/") {
            host = String(text[..<slash])
            path = String(text[slash...])
        }
        if let colon = host.firstIndex(of: ":") { host = String(host[..<colon]) }
        if host.hasPrefix("*.") { host.removeFirst(2) }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        while path.hasSuffix("/") { path.removeLast() }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
        guard !host.isEmpty,
              host.unicodeScalars.allSatisfy(allowed.contains),
              host.contains(".") || host == "localhost",
              !host.hasPrefix("."), !host.hasSuffix(".")
        else { return nil }

        self.host = host
        self.path = path
    }

    init(host: String, path: String) {
        self.host = host
        self.path = path
    }

    /// The form a rule is stored and shown in.
    public var text: String { host + path }

    public func matches(host candidate: String, path candidatePath: String) -> Bool {
        guard candidate == host || candidate.hasSuffix("." + host) else { return false }
        if path.isEmpty { return true }
        return candidatePath == path || candidatePath.hasPrefix(path + "/")
    }
}

/// Names that people type for a service whose pages live on another host.
/// A rule for the key also covers the values, so "gmail.com" reaches the inbox
/// at mail.google.com instead of matching nothing.
public enum SiteAliases {
    public static let table: [String: [String]] = [
        "x.com": ["twitter.com"],
        "twitter.com": ["x.com"],
        "gmail.com": ["mail.google.com"],
        "discord.com": ["discordapp.com"],
        "discordapp.com": ["discord.com"],
        "youtube.com": ["youtu.be"],
    ]

    public static func expansions(of rule: SiteRule) -> [SiteRule] {
        guard rule.path.isEmpty, let extra = table[rule.host] else { return [] }
        return extra.map { SiteRule(host: $0, path: "") }
    }
}

public struct SitePolicy: Equatable, Sendable {
    public let mode: ListMode
    public let rules: [SiteRule]

    public init(mode: ListMode, entries: [String]) {
        self.mode = mode
        var seen = Set<SiteRule>()
        var rules: [SiteRule] = []
        for rule in entries.compactMap(SiteRule.init) {
            for candidate in [rule] + SiteAliases.expansions(of: rule) where seen.insert(candidate).inserted {
                rules.append(candidate)
            }
        }
        self.rules = rules
    }

    /// True when the rules do something, so there is a reason to watch browsers.
    public var isActive: Bool { mode == .allow || !rules.isEmpty }

    /// Only web pages are judged. Browser pages, local files and blank tabs pass.
    public func blocks(_ urlString: String) -> Bool {
        guard let components = URLComponents(string: urlString),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              var host = components.host?.lowercased(), !host.isEmpty
        else { return false }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }

        let listed = rules.contains { $0.matches(host: host, path: path) }
        return mode == .block ? listed : !listed
    }

    /// Splits what someone typed or pasted into rule texts, dropping what isn't a site.
    public static func parse(_ input: String) -> [String] {
        input
            .split(whereSeparator: { $0 == "," || $0 == " " || $0.isNewline || $0 == ";" })
            .compactMap { SiteRule(String($0))?.text }
    }
}

extension SitePolicy {
    /// The part of a block list that can be enforced below the browser, by
    /// refusing connections: whole hosts. A rule with a path can't be, because
    /// an encrypted request shows only the host it is going to. An allow list
    /// can't be either, since refusing every other host would cut off every
    /// app on the Mac, not just the pages in them.
    public var networkHosts: [String] {
        guard mode == .block else { return [] }
        return rules.filter { $0.path.isEmpty }.map(\.host)
    }
}

/// The proxy auto-config file handed to macOS during a session. Every app that
/// follows the system proxy settings runs it for each request, which is how a
/// block reaches web views inside apps that are not browsers.
public enum ProxyAutoConfig {
    /// Requests for a listed host, or any subdomain of one, are sent to
    /// `proxy`, which refuses them. Everything else goes out as it would have.
    public static func source(blocking hosts: [String], via proxy: String) -> String {
        let list = hosts.map { "\"\($0)\"" }.joined(separator: ",")
        return """
            var blocked = [\(list)];
            function FindProxyForURL(url, host) {
              host = String(host).toLowerCase();
              for (var i = 0; i < blocked.length; i++) {
                var name = blocked[i];
                if (host === name) return "PROXY \(proxy)";
                var cut = host.length - name.length - 1;
                if (cut >= 0 && host.charAt(cut) === "." && host.indexOf(name, cut + 1) === cut + 1) return "PROXY \(proxy)";
              }
              return "DIRECT";
            }

            """
    }
}

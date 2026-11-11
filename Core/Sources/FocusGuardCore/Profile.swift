import Foundation

/// How a list is read: everything on it is blocked, or everything off it is.
public enum ListMode: String, Codable, CaseIterable, Sendable {
    case block
    case allow
}

public struct AppRef: Codable, Hashable, Identifiable, Sendable {
    public var bundleID: String
    public var name: String
    public var id: String { bundleID }

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

/// One set of rules. A profile does nothing until a Focus is connected to it.
public struct Profile: Codable, Equatable, Identifiable, Sendable {
    public static let defaultCooldown = 120
    public static let cooldownRange = 15...3600

    public var id: String
    public var name: String
    public var siteMode: ListMode
    public var sites: [String]
    public var appMode: ListMode
    public var apps: [AppRef]
    public var cooldownSeconds: Int

    public init(
        id: String = UUID().uuidString,
        name: String,
        siteMode: ListMode = .block,
        sites: [String] = [],
        appMode: ListMode = .block,
        apps: [AppRef] = [],
        cooldownSeconds: Int = Profile.defaultCooldown
    ) {
        self.id = id
        self.name = name
        self.siteMode = siteMode
        self.sites = sites
        self.appMode = appMode
        self.apps = apps
        self.cooldownSeconds = cooldownSeconds
    }

    public var sitePolicy: SitePolicy { SitePolicy(mode: siteMode, entries: sites) }

    public func appPolicy(exempt: Set<String>) -> AppPolicy {
        AppPolicy(mode: appMode, bundleIDs: Set(apps.map(\.bundleID)), exempt: exempt)
    }
}

public struct Config: Codable, Equatable, Sendable {
    public var profiles: [Profile]

    public init(profiles: [Profile] = []) {
        self.profiles = profiles
    }

    public func profile(_ id: String) -> Profile? {
        profiles.first { $0.id == id }
    }
}

public enum ConfigStore {
    public static func load(from url: URL) -> Config {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(Config.self, from: data)
        else { return Config() }
        return config
    }

    public static func save(_ config: Config, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(config).write(to: url, options: .atomic)
    }
}

public struct AppPolicy: Equatable, Sendable {
    public let mode: ListMode
    public let bundleIDs: Set<String>
    public let exempt: Set<String>

    public init(mode: ListMode, bundleIDs: Set<String>, exempt: Set<String> = []) {
        self.mode = mode
        self.bundleIDs = bundleIDs
        self.exempt = exempt
    }

    /// True when the rules do something, so there is a reason to watch apps.
    public var isActive: Bool { mode == .allow || !bundleIDs.isEmpty }

    public func blocks(_ bundleID: String) -> Bool {
        switch mode {
        case .block: return bundleIDs.contains(bundleID)
        case .allow: return !bundleIDs.contains(bundleID) && !exempt.contains(bundleID)
        }
    }
}

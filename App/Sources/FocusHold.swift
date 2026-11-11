import AppKit
import FocusGuardCore

/// Switching a Focus on or off from an app.
///
/// macOS gives apps no call for this. The one sanctioned route is the "Set
/// Focus" action in Shortcuts, so each profile can have two shortcuts, found by
/// name: one that turns its Focus on and one that turns it off. With them, the
/// Focus itself stays on through a cool-down. Without them, blocking still
/// lasts through the cool-down, but the Focus icon goes dark when clicked.
enum FocusHold {
    static func onName(_ profile: Profile) -> String { "Focus Guard On - \(profile.name)" }
    static func offName(_ profile: Profile) -> String { "Focus Guard Off - \(profile.name)" }

    private static let tool = URL(fileURLWithPath: "/usr/bin/shortcuts")

    static func list() async -> Set<String> {
        guard let output = await run(["list"]).output else { return [] }
        return Set(output.split(separator: "\n").map(String.init))
    }

    @discardableResult
    static func runShortcut(_ name: String) async -> Bool {
        let result = await run(["run", name])
        Log.write("hold: ran \"\(name)\" -> \(result.status)")
        return result.status == 0
    }

    /// Writes the two shortcuts for a profile and hands them to Shortcuts,
    /// which asks which Focus each one should set before adding it.
    static func offerShortcuts(for profile: Profile) async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("FocusGuardShortcuts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        for (name, enabled) in [(onName(profile), true), (offName(profile), false)] {
            let draft = folder.appendingPathComponent("draft-\(enabled ? "on" : "off").shortcut")
            let signed = folder.appendingPathComponent("\(name).shortcut")
            let data = try PropertyListSerialization.data(
                fromPropertyList: template(enabled: enabled, profileName: profile.name),
                format: .binary, options: 0)
            try data.write(to: draft)
            let result = await run(["sign", "--mode", "anyone", "--input", draft.path, "--output", signed.path])
            guard result.status == 0, FileManager.default.fileExists(atPath: signed.path) else {
                Log.write("hold: signing \"\(name)\" failed: \(result.output ?? "")")
                throw HoldError.signingFailed
            }
            await MainActor.run { _ = NSWorkspace.shared.open(signed) }
            // Shortcuts shows one "Add Shortcut" sheet at a time.
            try await Task.sleep(nanoseconds: 1_500_000_000)
        }
    }

    enum HoldError: LocalizedError {
        case signingFailed
        var errorDescription: String? {
            "Shortcuts could not prepare the files. Make the two shortcuts by hand instead."
        }
    }

    private static func template(enabled: Bool, profileName: String) -> [String: Any] {
        var parameters: [String: Any] = ["Enabled": enabled ? 1 : 0]
        if enabled { parameters["AssertionType"] = "Turned Off" }
        return [
            "WFWorkflowClientVersion": "2607.0.2",
            "WFWorkflowMinimumClientVersion": 900,
            "WFWorkflowMinimumClientVersionString": "900",
            "WFWorkflowIcon": [
                "WFWorkflowIconStartColor": 463_140_863,
                "WFWorkflowIconGlyphNumber": 59771,
            ],
            "WFWorkflowTypes": [String](),
            "WFWorkflowInputContentItemClasses": [String](),
            "WFWorkflowOutputContentItemClasses": [String](),
            "WFWorkflowHasShortcutInputVariables": false,
            "WFWorkflowHasOutputFallback": false,
            "WFWorkflowImportQuestions": [[
                "ActionIndex": 0,
                "Category": "Parameter",
                "ParameterKey": "FocusModes",
                "Text": "Which Focus is connected to the profile “\(profileName)”?",
            ]],
            "WFWorkflowActions": [[
                "WFWorkflowActionIdentifier": "is.workflow.actions.dnd.set",
                "WFWorkflowActionParameters": parameters,
            ]],
        ]
    }

    private static func run(_ arguments: [String]) async -> (status: Int32, output: String?) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = tool
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: (-1, nil))
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: (process.terminationStatus, String(data: data, encoding: .utf8)))
            }
        }
    }
}

import AppKit
import FocusGuardCore
import SQLite3
import UniformTypeIdentifiers

/// Image files attached to drafts. Each is copied into the drafts' own folder
/// when attached, so a draft doesn't break when the original is moved.
enum DraftMedia {
    /// The formats X takes as they are. Anything else is saved as PNG.
    private static let kept: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]
    /// X's limit for a photo.
    static let sizeLimit = 5 * 1024 * 1024

    static func url(for name: String) -> URL {
        Paths.media.appendingPathComponent(name)
    }

    static func store(fileAt source: URL) -> String? {
        let ext = source.pathExtension.lowercased()
        if kept.contains(ext) {
            let name = "\(UUID().uuidString).\(ext)"
            do {
                try FileManager.default.createDirectory(at: Paths.media, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: source, to: url(for: name))
                return name
            } catch {
                Log.write("drafts: could not copy image: \(error)")
                return nil
            }
        }
        guard let data = try? Data(contentsOf: source) else { return nil }
        return store(imageData: data)
    }

    /// Saves image data in whatever format it arrived in, as a PNG.
    static func store(imageData data: Data) -> String? {
        guard let image = NSBitmapImageRep(data: data) ?? NSImage(data: data)?.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)),
              let png = image.representation(using: .png, properties: [:])
        else { return nil }
        let name = "\(UUID().uuidString).png"
        do {
            try FileManager.default.createDirectory(at: Paths.media, withIntermediateDirectories: true)
            try png.write(to: url(for: name), options: .atomic)
            return name
        } catch {
            Log.write("drafts: could not save image: \(error)")
            return nil
        }
    }

    static func size(of name: String) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url(for: name).path))?[.size] as? Int ?? 0
    }

    /// Deletes image files that no draft points at any more.
    static func removeUnused(keeping inUse: Set<String>) {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: Paths.media.path) else { return }
        for file in files where !inUse.contains(file) {
            try? FileManager.default.removeItem(at: url(for: file))
        }
    }

    /// Puts the files on a pasteboard the way Finder's Copy does, which is
    /// what a browser's paste reads as attached files.
    @discardableResult
    static func copy(_ names: [String], to pasteboard: NSPasteboard) -> Bool {
        let urls = names.map { url(for: $0) as NSURL }
        guard !urls.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects(urls)
    }

    /// The image files on a pasteboard, and failing that an image copied as
    /// data, such as a screenshot. Text that came with an image wins: copying
    /// a paragraph from a page must paste as the paragraph.
    static func images(on pasteboard: NSPasteboard) -> (files: [URL], data: Data?) {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        if !files.isEmpty { return (files, nil) }
        if pasteboard.string(forType: .string) == nil,
           let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            return ([], data)
        }
        return ([], nil)
    }
}

/// Builds the people directory from the profiles opened in Chromium-family
/// browsers on this Mac. It reads two columns of the browser's history file,
/// address and page title, for X profile pages only, and sends nothing
/// anywhere. It runs when the person asks for it and at no other time.
enum PeopleImporter {
    private static let browsers = [
        "Google/Chrome", "Google/Chrome Beta", "BraveSoftware/Brave-Browser", "Microsoft Edge",
        "Arc/User Data", "Vivaldi", "Chromium", "com.operasoftware.Opera",
    ]

    static func historyFiles() -> [URL] {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var files: [URL] = []
        for browser in browsers {
            let root = support.appendingPathComponent(browser, isDirectory: true)
            let profiles = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            let candidates = [root] + profiles
                .filter { $0 == "Default" || $0.hasPrefix("Profile ") }
                .map { root.appendingPathComponent($0, isDirectory: true) }
            for folder in candidates {
                let history = folder.appendingPathComponent("History")
                if FileManager.default.fileExists(atPath: history.path) { files.append(history) }
            }
        }
        return files
    }

    /// Reads every history file found. Call off the main thread.
    static func run() -> (people: [Person], sources: Int) {
        var entries: [(url: String, title: String, visits: Int)] = []
        let files = historyFiles()
        for file in files {
            // The browser keeps its file locked while it runs. A copy isn't.
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("focusguard-history-\(UUID().uuidString).sqlite")
            defer { try? FileManager.default.removeItem(at: copy) }
            guard (try? FileManager.default.copyItem(at: file, to: copy)) != nil else { continue }
            entries += profilePages(in: copy)
        }
        return (XProfilePage.people(from: entries), files.count)
    }

    private static func profilePages(in file: URL) -> [(url: String, title: String, visits: Int)] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(file.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(database)
            return []
        }
        defer { sqlite3_close(database) }
        let query = """
            SELECT url, title, visit_count FROM urls
            WHERE title LIKE '%(@%'
              AND (url LIKE 'https://x.com/%' OR url LIKE 'https://twitter.com/%'
                OR url LIKE 'https://www.x.com/%' OR url LIKE 'https://www.twitter.com/%'
                OR url LIKE 'https://mobile.x.com/%' OR url LIKE 'https://mobile.twitter.com/%')
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var rows: [(url: String, title: String, visits: Int)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let url = sqlite3_column_text(statement, 0), let title = sqlite3_column_text(statement, 1) else { continue }
            rows.append((String(cString: url), String(cString: title), Int(sqlite3_column_int64(statement, 2))))
        }
        return rows
    }
}

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
        let urls = names.map { url(for: $0) }
        guard !urls.isEmpty else { return false }
        pasteboard.clearContents()
        guard pasteboard.writeObjects(urls as [NSURL]) else { return false }
        // Finder also writes the files as one list under an older name, and
        // that list is what Chrome reads. Without it Chrome's paste carries
        // the first file and drops the rest.
        pasteboard.setPropertyList(urls.map(\.path), forType: fileList)
        return true
    }

    private static let fileList = NSPasteboard.PasteboardType("NSFilenamesPboardType")

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

/// Adds a draft's images to X's post box after the compose page is opened,
/// by telling the browser to paste. See `ComposeAttach` for why and how.
@MainActor
final class ComposeAttacher {
    enum State: Equatable {
        case working
        /// The page shows every image.
        case attached
        /// The page shows this many of them.
        case partial(Int)
        /// Pasted, in a browser that doesn't let the page be checked.
        case pasted
        /// Nothing was pasted, or it didn't take. The images are on the
        /// clipboard for the person to paste.
        case manual
    }

    // Its own thread: waiting for a page to load must not hold up the
    // scripts that watch tabs during a session.
    private let runner = ScriptRunner()

    /// `clipboard` is the pasteboard's change count right after the images
    /// were copied. If something else is copied while the page loads, pasting
    /// would put that into the box, so nothing is pasted.
    func attach(count: Int, to address: URL, clipboard: Int, update: @escaping (State) -> Void) {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: address),
              let bundleID = Bundle(url: app)?.bundleIdentifier,
              Browsers.readable[bundleID] == .chromium
        else {
            Log.write("drafts: images left on the clipboard; this browser can't be told to paste")
            return update(.manual)
        }
        update(.working)
        let locate = ComposeAttach.locateScript(bundleID: bundleID, address: address.absoluteString)
        runner.run(locate) { [runner] result in
            guard case .success(let output) = result, let target = ComposeAttach.parseLocate(output) else {
                if case .failure(let error) = result {
                    Log.write("drafts: could not reach the compose page: \(error.code) \(error.message)")
                } else {
                    Log.write("drafts: the compose page didn't turn up; images left on the clipboard")
                }
                return update(.manual)
            }
            guard NSPasteboard.general.changeCount == clipboard else {
                Log.write("drafts: the clipboard changed while X loaded; nothing pasted")
                return update(.manual)
            }
            runner.run(ComposeAttach.pasteScript(bundleID: bundleID, target: target, expecting: count)) { result in
                guard case .success(let output) = result else {
                    if case .failure(let error) = result {
                        Log.write("drafts: paste into X failed: \(error.code) \(error.message)")
                    }
                    return update(.manual)
                }
                switch ComposeAttach.parsePaste(output, target: target) {
                case .attached(let added) where added >= count:
                    Log.write("drafts: X shows \(added) image(s) added")
                    update(.attached)
                case .attached(0):
                    Log.write("drafts: pasted, but X shows no image")
                    update(.manual)
                case .attached(let added):
                    Log.write("drafts: X shows \(added) of \(count) image(s)")
                    update(.partial(added))
                case .pasted:
                    Log.write("drafts: pasted \(count) image(s) into X, unchecked")
                    update(.pasted)
                }
            }
        }
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

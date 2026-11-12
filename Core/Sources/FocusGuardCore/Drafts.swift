import Foundation

/// A post written while X was blocked, kept on this Mac until it can be sent.
public struct TweetDraft: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var text: String
    public var createdAt: Date
    /// When X's compose page was opened with this text. Whether it was then
    /// posted can't be seen from here, so the draft stays until it is removed.
    public var openedAt: Date?

    public init(id: String = UUID().uuidString, text: String, createdAt: Date, openedAt: Date? = nil) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.openedAt = openedAt
    }
}

/// Everything saved about drafts: the drafts, and the handles tagged before.
public struct DraftBook: Codable, Equatable, Sendable {
    public static let handleMemory = 200

    /// Newest first.
    public private(set) var drafts: [TweetDraft]
    /// Handles used in earlier drafts, most recent first. They are what the
    /// composer offers while a tag is being typed. X can't be asked who exists
    /// while it is blocked, so the list is only ever what was typed here.
    public private(set) var handles: [String]

    public init(drafts: [TweetDraft] = [], handles: [String] = []) {
        self.drafts = drafts
        self.handles = handles
    }

    /// Adds a draft, or replaces the text of the one with `id`. Returns nil,
    /// and changes nothing, when the text is blank.
    @discardableResult
    public mutating func save(text: String, replacing id: String? = nil, now: Date) -> TweetDraft? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        remember(TweetText.mentions(in: trimmed))
        if let id, let index = drafts.firstIndex(where: { $0.id == id }) {
            drafts[index].text = trimmed
            drafts[index].openedAt = nil
            return drafts[index]
        }
        let draft = TweetDraft(text: trimmed, createdAt: now)
        drafts.insert(draft, at: 0)
        return draft
    }

    @discardableResult
    public mutating func remove(_ id: String) -> TweetDraft? {
        guard let index = drafts.firstIndex(where: { $0.id == id }) else { return nil }
        return drafts.remove(at: index)
    }

    /// Puts back a draft that was removed, where its date says it belongs.
    public mutating func restore(_ draft: TweetDraft) {
        guard !drafts.contains(where: { $0.id == draft.id }) else { return }
        let index = drafts.firstIndex { $0.createdAt < draft.createdAt } ?? drafts.endIndex
        drafts.insert(draft, at: index)
    }

    public mutating func markOpened(_ id: String, now: Date?) {
        guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        drafts[index].openedAt = now
    }

    private mutating func remember(_ used: [String]) {
        for handle in used.reversed() {
            handles.removeAll { $0.caseInsensitiveCompare(handle) == .orderedSame }
            handles.insert(handle, at: 0)
        }
        if handles.count > Self.handleMemory { handles.removeLast(handles.count - Self.handleMemory) }
    }

    /// Handles to offer for the part of a tag typed so far. An empty `partial`
    /// (just "@") offers the most recent ones.
    public func suggestions(for partial: String, limit: Int = 6) -> [String] {
        let wanted = partial.lowercased()
        let matches = handles.filter { handle in
            let lower = handle.lowercased()
            return wanted.isEmpty || (lower.hasPrefix(wanted) && lower != wanted)
        }
        return Array(matches.prefix(limit))
    }
}

public enum DraftStore {
    public static func load(from url: URL) -> DraftBook {
        guard let data = try? Data(contentsOf: url),
              let book = try? JSONDecoder().decode(DraftBook.self, from: data)
        else { return DraftBook() }
        return book
    }

    public static func save(_ book: DraftBook, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(book).write(to: url, options: .atomic)
    }
}

/// What X does with the text of a post: who it tags, how long it counts as,
/// and the address that opens its compose page with the text filled in.
public enum TweetText {
    public static let limit = 280
    public static let handleLimit = 15

    private static func isHandleCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || character == "_")
    }

    /// The handles tagged in `text`, without the "@", in order, each once.
    /// An "@" inside a word, as in an email address, is not a tag.
    public static func mentions(in text: String) -> [String] {
        var found: [String] = []
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            defer { index += 1 }
            guard characters[index] == "@" else { continue }
            if index > 0, isHandleCharacter(characters[index - 1]) || characters[index - 1] == "@" { continue }
            var end = index + 1
            while end < characters.count, isHandleCharacter(characters[end]) { end += 1 }
            let handle = String(characters[(index + 1)..<end])
            index = end - 1
            guard !handle.isEmpty, handle.count <= handleLimit else { continue }
            if !found.contains(where: { $0.caseInsensitiveCompare(handle) == .orderedSame }) {
                found.append(handle)
            }
        }
        return found
    }

    /// The part of a tag being typed at the end of `text`: "" after a bare
    /// "@", "par" after "@par", nil when the text doesn't end in a tag.
    public static func trailingMention(in text: String) -> String? {
        let characters = Array(text)
        var start = characters.count
        while start > 0, isHandleCharacter(characters[start - 1]) { start -= 1 }
        guard start > 0, characters[start - 1] == "@" else { return nil }
        if start > 1, isHandleCharacter(characters[start - 2]) || characters[start - 2] == "@" { return nil }
        let partial = String(characters[start...])
        return partial.count <= handleLimit ? partial : nil
    }

    /// `text` with the tag being typed at its end finished as `handle`.
    public static func completing(_ text: String, with handle: String) -> String {
        guard let partial = trailingMention(in: text) else { return text }
        return String(text.dropLast(partial.count)) + handle + " "
    }

    /// The length X counts. A link counts as 23 whatever its real length, and
    /// characters outside the Latin-script ranges, emoji among them, as two.
    public static func length(of text: String) -> Int {
        var remaining = text.precomposedStringWithCanonicalMapping
        var total = 0
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let whole = NSRange(remaining.startIndex..., in: remaining)
            for match in detector.matches(in: remaining, range: whole).reversed() {
                guard let scheme = match.url?.scheme, scheme == "http" || scheme == "https",
                      let range = Range(match.range, in: remaining)
                else { continue }
                remaining.removeSubrange(range)
                total += 23
            }
        }
        for character in remaining {
            let light = character.unicodeScalars.allSatisfy { scalar in
                switch scalar.value {
                case 0...4351, 8192...8205, 8208...8223, 8242...8247: return true
                default: return false
                }
            }
            total += light ? character.unicodeScalars.count : 2
        }
        return total
    }

    /// X's compose page, opened with `text` in the box. Nothing is posted
    /// until Post is pressed there.
    public static func composeURL(for text: String) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encoded = text.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://x.com/intent/post?text=\(encoded)")
    }
}

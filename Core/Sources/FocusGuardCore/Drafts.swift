import Foundation

/// A post written while X was blocked, kept on this Mac until it can be sent.
public struct TweetDraft: Codable, Equatable, Identifiable, Sendable {
    public static let imageLimit = 4

    public var id: String
    public var text: String
    /// File names of attached images, in the drafts' media folder.
    public var images: [String]
    public var createdAt: Date
    /// When X's compose page was opened with this text. Whether it was then
    /// posted can't be seen from here, so the draft stays until it is removed.
    public var openedAt: Date?

    public init(
        id: String = UUID().uuidString, text: String, images: [String] = [],
        createdAt: Date, openedAt: Date? = nil
    ) {
        self.id = id
        self.text = text
        self.images = images
        self.createdAt = createdAt
        self.openedAt = openedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        text = try values.decode(String.self, forKey: .text)
        images = try values.decodeIfPresent([String].self, forKey: .images) ?? []
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        openedAt = try values.decodeIfPresent(Date.self, forKey: .openedAt)
    }
}

/// Someone who can be offered while a tag is being typed.
public struct Person: Codable, Equatable, Identifiable, Sendable {
    public var handle: String
    public var name: String?
    /// How many times their profile was opened in the browser, when they came
    /// from an import. Zero for someone only ever typed here.
    public var visits: Int
    /// When they were last tagged in a draft.
    public var lastUsed: Date?

    public var id: String { handle.lowercased() }

    public init(handle: String, name: String? = nil, visits: Int = 0, lastUsed: Date? = nil) {
        self.handle = handle
        self.name = name
        self.visits = visits
        self.lastUsed = lastUsed
    }
}

/// Everything saved about drafts: the drafts, and the people who can be tagged.
public struct DraftBook: Codable, Equatable, Sendable {
    public static let peopleLimit = 5000

    /// Newest first.
    public private(set) var drafts: [TweetDraft]
    /// The directory the composer searches while a tag is typed. X can't be
    /// asked who exists while it is blocked, so this is built on the Mac: from
    /// tags typed in earlier drafts, and from an import the person asks for.
    public private(set) var people: [Person]

    public init(drafts: [TweetDraft] = [], people: [Person] = []) {
        self.drafts = drafts
        self.people = people
    }

    private enum CodingKeys: String, CodingKey {
        case drafts, people, handles
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        drafts = try values.decodeIfPresent([TweetDraft].self, forKey: .drafts) ?? []
        if let people = try values.decodeIfPresent([Person].self, forKey: .people) {
            self.people = people
        } else {
            // Files written before people had names held bare handles.
            let handles = try values.decodeIfPresent([String].self, forKey: .handles) ?? []
            people = handles.map { Person(handle: $0) }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(drafts, forKey: .drafts)
        try values.encode(people, forKey: .people)
    }

    /// Adds a draft, or replaces the one with `id`. Returns nil, and changes
    /// nothing, when there is neither text nor an image.
    @discardableResult
    public mutating func save(
        text: String, images: [String] = [], replacing id: String? = nil, now: Date
    ) -> TweetDraft? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty else { return nil }
        let kept = Array(images.prefix(TweetDraft.imageLimit))
        remember(TweetText.mentions(in: trimmed), now: now)
        if let id, let index = drafts.firstIndex(where: { $0.id == id }) {
            drafts[index].text = trimmed
            drafts[index].images = kept
            drafts[index].openedAt = nil
            return drafts[index]
        }
        let draft = TweetDraft(text: trimmed, images: kept, createdAt: now)
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

    /// Every image file a draft still points at.
    public var imagesInUse: Set<String> {
        Set(drafts.flatMap(\.images))
    }

    private mutating func remember(_ handles: [String], now: Date) {
        for handle in handles {
            if let index = people.firstIndex(where: { $0.id == handle.lowercased() }) {
                people[index].lastUsed = now
            } else {
                people.append(Person(handle: handle, lastUsed: now))
            }
        }
    }

    /// Adds people from an import. Someone already known keeps when they were
    /// last tagged and gains the name and visit count the import found.
    /// Returns how many were new.
    @discardableResult
    public mutating func merge(_ imported: [Person]) -> Int {
        var added = 0
        var index = Dictionary(uniqueKeysWithValues: people.enumerated().map { ($1.id, $0) })
        for person in imported {
            if let position = index[person.id] {
                if let name = person.name, !name.isEmpty { people[position].name = name }
                people[position].visits = max(people[position].visits, person.visits)
                if people[position].name != nil { people[position].handle = person.handle }
            } else {
                index[person.id] = people.count
                people.append(person)
                added += 1
            }
        }
        if people.count > Self.peopleLimit {
            people = Array(ranked(people).prefix(Self.peopleLimit))
        }
        return added
    }

    /// People to offer for the part of a tag typed so far, best first. The
    /// text is matched against the start of the handle and the start of any
    /// word of the name, as X does. An empty `partial` (just "@") offers the
    /// people most likely to be wanted.
    public func suggestions(for partial: String, limit: Int = 6) -> [Person] {
        let wanted = partial.lowercased()
        if wanted.isEmpty { return Array(ranked(people).prefix(limit)) }

        var byHandle: [Person] = []
        var byName: [Person] = []
        for person in people {
            if person.id.hasPrefix(wanted) {
                byHandle.append(person)
            } else if let name = person.name?.lowercased() {
                let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                if words.contains(where: { $0.hasPrefix(wanted) }) || words.joined().hasPrefix(wanted) {
                    byName.append(person)
                }
            }
        }
        // An exact handle leads, so a finished tag shows who it is.
        let exact = byHandle.filter { $0.id == wanted }
        let rest = ranked(byHandle.filter { $0.id != wanted })
        return Array((exact + rest + ranked(byName)).prefix(limit))
    }

    /// Tagged here most recently first, then most visited, then by handle.
    private func ranked(_ list: [Person]) -> [Person] {
        list.sorted { first, second in
            switch (first.lastUsed, second.lastUsed) {
            case let (a?, b?) where a != b: return a > b
            case (_?, nil): return true
            case (nil, _?): return false
            default: break
            }
            if first.visits != second.visits { return first.visits > second.visits }
            return first.id < second.id
        }
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

/// A browser history entry read as an X profile. This is the import that
/// fills the people directory: every profile opened in the browser left an
/// address and a page title, and the title carries the display name.
public enum XProfilePage {
    /// First path segments that are pages of X itself and never someone's handle.
    static let reserved: Set<String> = [
        "home", "explore", "search", "notifications", "messages", "settings", "compose", "intent",
        "i", "hashtag", "login", "logout", "signup", "tos", "privacy", "about", "jobs", "share",
        "account", "following", "followers", "lists", "bookmarks", "communities", "premium", "download",
    ]

    /// The person a history entry is the profile of, or nil when the entry is
    /// some other page. Only the profile's own address counts: a post, a
    /// search or a settings page under the same site says nothing reliable
    /// about a name.
    public static func person(url: String, title: String, visits: Int) -> Person? {
        guard let components = URLComponents(string: url),
              var host = components.host?.lowercased()
        else { return nil }
        for prefix in ["www.", "mobile."] where host.hasPrefix(prefix) { host.removeFirst(prefix.count) }
        guard host == "x.com" || host == "twitter.com" else { return nil }

        let segments = components.path.split(separator: "/")
        guard segments.count == 1 else { return nil }
        let handle = String(segments[0])
        guard handle.count <= TweetText.handleLimit,
              handle.unicodeScalars.allSatisfy({ TweetText.isHandleUnit(UInt16(truncatingIfNeeded: $0.value)) && $0.isASCII }),
              !reserved.contains(handle.lowercased())
        else { return nil }

        // "Andrej Karpathy (@karpathy) / X", sometimes led by "(3) ".
        var name: String?
        if let marker = title.range(of: " (@\(handle))", options: [.caseInsensitive, .backwards]) {
            var candidate = String(title[..<marker.lowerBound])
            if candidate.hasPrefix("("), let close = candidate.firstIndex(of: ")"),
               candidate[candidate.index(after: candidate.startIndex)..<close].allSatisfy({ $0.isNumber || $0 == "+" }) {
                candidate = String(candidate[candidate.index(after: close)...])
            }
            candidate = candidate.trimmingCharacters(in: .whitespaces)
            if !candidate.isEmpty { name = candidate }
        }
        // Without the title's confirmation an address is only a guess at a
        // profile, and guesses would fill the list with pages that aren't people.
        guard name != nil else { return nil }
        return Person(handle: handle, name: name, visits: max(visits, 1))
    }

    /// Folds many history entries into one list, adding up the visits to
    /// different addresses of the same profile.
    public static func people(from entries: [(url: String, title: String, visits: Int)]) -> [Person] {
        var found: [String: Person] = [:]
        for entry in entries {
            guard let person = person(url: entry.url, title: entry.title, visits: entry.visits) else { continue }
            if var known = found[person.id] {
                known.visits += person.visits
                found[person.id] = known
            } else {
                found[person.id] = person
            }
        }
        return found.values.sorted { $0.visits != $1.visits ? $0.visits > $1.visits : $0.id < $1.id }
    }
}

/// What X does with the text of a post: who it tags, which parts are links,
/// how long it counts as, and the address that opens its compose page with
/// the text filled in.
///
/// Positions are in UTF-16 units, the units a text view counts in.
public enum TweetText {
    public static let limit = 280
    public static let handleLimit = 15

    public struct Span: Equatable, Sendable {
        public enum Kind: Sendable { case mention, link }
        public let kind: Kind
        public let location: Int
        public let length: Int
        /// The handle without "@", or the link's address.
        public let value: String
    }

    static func isHandleUnit(_ unit: UInt16) -> Bool {
        (unit >= 48 && unit <= 57) || (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) || unit == 95
    }

    private static let at: UInt16 = 64

    /// The tags and links in `text`, in order. An "@" inside a word, as in an
    /// email address, is not a tag, and nothing inside a link is one either.
    public static func spans(in text: String) -> [Span] {
        var spans: [Span] = []
        let whole = NSRange(location: 0, length: (text as NSString).length)
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for match in detector.matches(in: text, range: whole) {
                guard let url = match.url, let scheme = url.scheme, scheme == "http" || scheme == "https" else { continue }
                spans.append(Span(kind: .link, location: match.range.location, length: match.range.length, value: url.absoluteString))
            }
        }
        let links = spans

        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            defer { index += 1 }
            guard units[index] == at else { continue }
            if index > 0, isHandleUnit(units[index - 1]) || units[index - 1] == at { continue }
            var end = index + 1
            while end < units.count, isHandleUnit(units[end]) { end += 1 }
            let length = end - index - 1
            let start = index
            index = end - 1
            guard length >= 1, length <= handleLimit else { continue }
            if links.contains(where: { start >= $0.location && start < $0.location + $0.length }) { continue }
            let handle = String(utf16CodeUnits: Array(units[(start + 1)..<end]), count: length)
            spans.append(Span(kind: .mention, location: start, length: length + 1, value: handle))
        }
        return spans.sorted { $0.location < $1.location }
    }

    /// The handles tagged in `text`, without the "@", in order, each once.
    public static func mentions(in text: String) -> [String] {
        var found: [String] = []
        for span in spans(in: text) where span.kind == .mention {
            if !found.contains(where: { $0.caseInsensitiveCompare(span.value) == .orderedSame }) {
                found.append(span.value)
            }
        }
        return found
    }

    /// The links in `text`, in order, each once.
    public static func links(in text: String) -> [String] {
        var found: [String] = []
        for span in spans(in: text) where span.kind == .link && !found.contains(span.value) {
            found.append(span.value)
        }
        return found
    }

    /// The tag being typed where the caret is: the range of the whole "@word"
    /// the caret is in or at the end of, and the part of it before the caret.
    /// Nil when the caret isn't in a tag.
    public static func mentionBeingTyped(in text: String, caret: Int) -> (location: Int, length: Int, partial: String)? {
        let units = Array(text.utf16)
        guard caret >= 0, caret <= units.count else { return nil }
        var start = caret
        while start > 0, isHandleUnit(units[start - 1]) { start -= 1 }
        guard start > 0, units[start - 1] == at else { return nil }
        let sign = start - 1
        if sign > 0, isHandleUnit(units[sign - 1]) || units[sign - 1] == at { return nil }
        var end = caret
        while end < units.count, isHandleUnit(units[end]) { end += 1 }
        guard end - start <= handleLimit else { return nil }
        let partial = String(utf16CodeUnits: Array(units[start..<caret]), count: caret - start)
        return (sign, end - sign, partial)
    }

    /// The part of a tag being typed at the very end of `text`.
    public static func trailingMention(in text: String) -> String? {
        mentionBeingTyped(in: text, caret: (text as NSString).length)?.partial
    }

    /// `text` with the tag being typed at its end finished as `handle`.
    public static func completing(_ text: String, with handle: String) -> String {
        let length = (text as NSString).length
        guard let typed = mentionBeingTyped(in: text, caret: length) else { return text }
        return (text as NSString).replacingCharacters(
            in: NSRange(location: typed.location, length: typed.length), with: "@\(handle) ")
    }

    /// The length X counts. A link counts as 23 whatever its real length, and
    /// characters outside the Latin-script ranges, emoji among them, as two.
    public static func length(of text: String) -> Int {
        var remaining = text.precomposedStringWithCanonicalMapping
        var total = 0
        for span in spans(in: remaining).reversed() where span.kind == .link {
            guard let range = Range(NSRange(location: span.location, length: span.length), in: remaining) else { continue }
            remaining.removeSubrange(range)
            total += 23
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
    /// until Post is pressed there. Images can't be passed this way.
    public static func composeURL(for text: String) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encoded = text.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://x.com/intent/post?text=\(encoded)")
    }
}

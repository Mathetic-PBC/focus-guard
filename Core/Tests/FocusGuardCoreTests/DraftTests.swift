import XCTest
@testable import FocusGuardCore

final class DraftTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testMentionsAreFoundInOrderAndOnce() {
        XCTAssertEqual(
            TweetText.mentions(in: "@karpathy this with @dwarkesh_sp, and again @Karpathy."),
            ["karpathy", "dwarkesh_sp"])
    }

    func testAtSignInsideAWordIsNotATag() {
        XCTAssertEqual(TweetText.mentions(in: "mail me at someone@example.com or @@ or @"), [])
        XCTAssertEqual(TweetText.mentions(in: "(@a) \n@b_2"), ["a", "b_2"])
    }

    func testHandleLongerThanXAllowsIsNotATag() {
        XCTAssertEqual(TweetText.mentions(in: "@abcdefghijklmnop"), [])
        XCTAssertEqual(TweetText.mentions(in: "@abcdefghijklmno"), ["abcdefghijklmno"])
    }

    func testTrailingMentionIsThePartBeingTyped() {
        XCTAssertEqual(TweetText.trailingMention(in: "thanks @"), "")
        XCTAssertEqual(TweetText.trailingMention(in: "thanks @dwa"), "dwa")
        XCTAssertEqual(TweetText.trailingMention(in: "@dwa"), "dwa")
        XCTAssertNil(TweetText.trailingMention(in: "thanks @dwa "))
        XCTAssertNil(TweetText.trailingMention(in: "someone@exa"))
        XCTAssertNil(TweetText.trailingMention(in: "no tag here"))
    }

    func testCompletingReplacesOnlyThePartBeingTyped() {
        XCTAssertEqual(TweetText.completing("thanks @dwa", with: "dwarkesh_sp"), "thanks @dwarkesh_sp ")
        XCTAssertEqual(TweetText.completing("thanks @", with: "karpathy"), "thanks @karpathy ")
        XCTAssertEqual(TweetText.completing("no tag", with: "karpathy"), "no tag")
    }

    func testLengthCountsLinksAsTwentyThreeAndEmojiAsTwo() {
        XCTAssertEqual(TweetText.length(of: "hello"), 5)
        XCTAssertEqual(TweetText.length(of: "read https://example.com/a/very/long/path/that/goes/on/and/on?x=1"), 5 + 23)
        XCTAssertEqual(TweetText.length(of: "ok 👍"), 3 + 2)
        XCTAssertEqual(TweetText.length(of: "日本"), 4)
        XCTAssertEqual(TweetText.length(of: "café"), 4)
    }

    func testComposeURLCarriesTheTextIntact() throws {
        let text = "1 + 1 = 2 & that's it #math @karpathy\nline two"
        let url = try XCTUnwrap(TweetText.composeURL(for: text))
        XCTAssertEqual(url.host, "x.com")
        XCTAssertEqual(url.path, "/intent/post")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.value, text)
        // A raw "+" would arrive as a space, and a raw "&" would cut the text short.
        XCTAssertFalse(url.absoluteString.contains("+"))
        XCTAssertEqual(url.absoluteString.filter { $0 == "&" }.count, 0)
    }

    func testSavingKeepsNewestFirstAndIgnoresBlankText() {
        var book = DraftBook()
        XCTAssertNil(book.save(text: "  \n ", now: t0))
        book.save(text: "first", now: t0)
        book.save(text: "  second  ", now: t0.addingTimeInterval(60))
        XCTAssertEqual(book.drafts.map(\.text), ["second", "first"])
    }

    func testEditingReplacesTextAndClearsOpened() throws {
        var book = DraftBook()
        let draft = try XCTUnwrap(book.save(text: "frist", now: t0))
        book.markOpened(draft.id, now: t0)
        book.save(text: "first", replacing: draft.id, now: t0.addingTimeInterval(5))
        XCTAssertEqual(book.drafts.count, 1)
        XCTAssertEqual(book.drafts[0].text, "first")
        XCTAssertNil(book.drafts[0].openedAt)
        XCTAssertEqual(book.drafts[0].createdAt, t0)
    }

    func testRemoveThenRestorePutsTheDraftBackInPlace() throws {
        var book = DraftBook()
        book.save(text: "a", now: t0)
        let middle = try XCTUnwrap(book.save(text: "b", now: t0.addingTimeInterval(1)))
        book.save(text: "c", now: t0.addingTimeInterval(2))
        XCTAssertEqual(book.remove(middle.id), middle)
        XCTAssertEqual(book.drafts.map(\.text), ["c", "a"])
        book.restore(middle)
        book.restore(middle)
        XCTAssertEqual(book.drafts.map(\.text), ["c", "b", "a"])
    }

    func testHandlesAreRememberedMostRecentFirst() {
        var book = DraftBook()
        book.save(text: "@karpathy @dwarkesh_sp", now: t0)
        book.save(text: "again @Karpathy and @tylercowen", now: t0)
        XCTAssertEqual(book.handles, ["Karpathy", "tylercowen", "dwarkesh_sp"])
    }

    func testSuggestionsMatchByPrefixWhateverTheCase() {
        var book = DraftBook()
        book.save(text: "@karpathy @dwarkesh_sp @DarioAmodei", now: t0)
        XCTAssertEqual(book.suggestions(for: "d"), ["dwarkesh_sp", "DarioAmodei"])
        XCTAssertEqual(book.suggestions(for: "DA"), ["DarioAmodei"])
        XCTAssertEqual(book.suggestions(for: ""), ["karpathy", "dwarkesh_sp", "DarioAmodei"])
        XCTAssertEqual(book.suggestions(for: "karpathy"), [])
        XCTAssertEqual(book.suggestions(for: "zz"), [])
    }

    func testDraftsRoundTripThroughDisk() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("drafts.json")
        var book = DraftBook()
        book.save(text: "hello @karpathy", now: t0)
        try DraftStore.save(book, to: url)
        XCTAssertEqual(DraftStore.load(from: url), book)
        XCTAssertEqual(DraftStore.load(from: url.appendingPathExtension("missing")), DraftBook())
    }
}

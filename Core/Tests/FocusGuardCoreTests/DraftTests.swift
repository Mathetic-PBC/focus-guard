import XCTest
@testable import FocusGuardCore

final class DraftTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    // MARK: Tags

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

    func testAtSignInsideALinkIsNotATag() {
        XCTAssertEqual(TweetText.mentions(in: "see https://medium.com/@someone/post and @real"), ["real"])
    }

    func testTrailingMentionIsThePartBeingTyped() {
        XCTAssertEqual(TweetText.trailingMention(in: "thanks @"), "")
        XCTAssertEqual(TweetText.trailingMention(in: "thanks @dwa"), "dwa")
        XCTAssertEqual(TweetText.trailingMention(in: "@dwa"), "dwa")
        XCTAssertNil(TweetText.trailingMention(in: "thanks @dwa "))
        XCTAssertNil(TweetText.trailingMention(in: "someone@exa"))
        XCTAssertNil(TweetText.trailingMention(in: "no tag here"))
    }

    func testMentionAtTheCaretCoversTheWholeWord() throws {
        // Caret after "@dwa" in the middle of the text, with "rk" still to its right.
        let text = "hi @dwark and more"
        let typed = try XCTUnwrap(TweetText.mentionBeingTyped(in: text, caret: 7))
        XCTAssertEqual(typed.partial, "dwa")
        XCTAssertEqual(typed.location, 3)
        XCTAssertEqual(typed.length, 6)
        XCTAssertNil(TweetText.mentionBeingTyped(in: text, caret: 2))
        XCTAssertNil(TweetText.mentionBeingTyped(in: text, caret: 12))
    }

    func testMentionPositionsCountEmojiAsATextViewDoes() throws {
        let text = "👍 @ka"
        let typed = try XCTUnwrap(TweetText.mentionBeingTyped(in: text, caret: (text as NSString).length))
        XCTAssertEqual(typed.location, 3)
        XCTAssertEqual(typed.partial, "ka")
    }

    func testCompletingReplacesOnlyThePartBeingTyped() {
        XCTAssertEqual(TweetText.completing("thanks @dwa", with: "dwarkesh_sp"), "thanks @dwarkesh_sp ")
        XCTAssertEqual(TweetText.completing("thanks @", with: "karpathy"), "thanks @karpathy ")
        XCTAssertEqual(TweetText.completing("no tag", with: "karpathy"), "no tag")
    }

    // MARK: Links and length

    func testLinksAreFoundOnce() {
        XCTAssertEqual(
            TweetText.links(in: "a https://example.com/x b http://example.org. again https://example.com/x"),
            ["https://example.com/x", "http://example.org"])
        XCTAssertEqual(TweetText.links(in: "mailto:me@example.com is not a web link"), [])
    }

    func testSpansGiveRangesATextViewCanColour() {
        let text = "hey @karpathy read https://example.com now"
        let spans = TweetText.spans(in: text)
        XCTAssertEqual(spans.map(\.kind), [.mention, .link])
        XCTAssertEqual((text as NSString).substring(with: NSRange(location: spans[0].location, length: spans[0].length)), "@karpathy")
        XCTAssertEqual((text as NSString).substring(with: NSRange(location: spans[1].location, length: spans[1].length)), "https://example.com")
    }

    func testLengthCountsLinksAsTwentyThreeAndEmojiAsTwo() {
        XCTAssertEqual(TweetText.length(of: "hello"), 5)
        XCTAssertEqual(TweetText.length(of: "read https://example.com/a/very/long/path/that/goes/on/and/on?x=1"), 5 + 23)
        XCTAssertEqual(TweetText.length(of: "ok 👍"), 3 + 2)
        XCTAssertEqual(TweetText.length(of: "日本"), 4)
        XCTAssertEqual(TweetText.length(of: "café"), 4)
    }

    func testComposeURLCarriesTheTextIntact() throws {
        let text = "1 + 1 = 2 & that's it #math @karpathy\nline two https://example.com/?a=1&b=2"
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

    // MARK: Drafts

    func testSavingKeepsNewestFirstAndIgnoresAnEmptyDraft() {
        var book = DraftBook()
        XCTAssertNil(book.save(text: "  \n ", now: t0))
        book.save(text: "first", now: t0)
        book.save(text: "  second  ", now: t0.addingTimeInterval(60))
        XCTAssertEqual(book.drafts.map(\.text), ["second", "first"])
    }

    func testADraftCanBeImagesAlone() throws {
        var book = DraftBook()
        let draft = try XCTUnwrap(book.save(text: "", images: ["a.png"], now: t0))
        XCTAssertEqual(draft.images, ["a.png"])
        XCTAssertEqual(draft.text, "")
    }

    func testNoMoreImagesAreKeptThanXTakes() throws {
        var book = DraftBook()
        let draft = try XCTUnwrap(book.save(text: "x", images: ["1", "2", "3", "4", "5"], now: t0))
        XCTAssertEqual(draft.images, ["1", "2", "3", "4"])
        XCTAssertEqual(book.imagesInUse, ["1", "2", "3", "4"])
    }

    func testEditingReplacesTextAndImagesAndClearsOpened() throws {
        var book = DraftBook()
        let draft = try XCTUnwrap(book.save(text: "frist", images: ["a.png"], now: t0))
        book.markOpened(draft.id, now: t0)
        book.save(text: "first", images: ["b.png"], replacing: draft.id, now: t0.addingTimeInterval(5))
        XCTAssertEqual(book.drafts.count, 1)
        XCTAssertEqual(book.drafts[0].text, "first")
        XCTAssertEqual(book.drafts[0].images, ["b.png"])
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

    func testDraftsRoundTripThroughDisk() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("drafts.json")
        var book = DraftBook()
        book.save(text: "hello @karpathy", images: ["a.png"], now: t0)
        book.merge([Person(handle: "karpathy", name: "Andrej Karpathy", visits: 9)])
        try DraftStore.save(book, to: url)
        XCTAssertEqual(DraftStore.load(from: url), book)
        XCTAssertEqual(DraftStore.load(from: url.appendingPathExtension("missing")), DraftBook())
    }

    func testAFileFromBeforeImagesAndNamesStillLoads() throws {
        let old = #"{"drafts":[{"id":"D1","text":"hi @a","createdAt":1000}],"handles":["karpathy","a"]}"#
        let book = try JSONDecoder().decode(DraftBook.self, from: Data(old.utf8))
        XCTAssertEqual(book.drafts.first?.images, [])
        XCTAssertEqual(book.people.map(\.handle), ["karpathy", "a"])
    }

    // MARK: People

    func people() -> DraftBook {
        var book = DraftBook()
        book.merge([
            Person(handle: "karpathy", name: "Andrej Karpathy", visits: 40),
            Person(handle: "dwarkesh_sp", name: "Dwarkesh Patel", visits: 25),
            Person(handle: "DarioAmodei", name: "Dario Amodei", visits: 12),
            Person(handle: "tylercowen", name: "Tyler Cowen", visits: 30),
            Person(handle: "patrickc", name: "Patrick Collison", visits: 8),
        ])
        return book
    }

    func testSuggestionsMatchTheStartOfTheHandle() {
        XCTAssertEqual(people().suggestions(for: "d").map(\.handle), ["dwarkesh_sp", "DarioAmodei"])
        XCTAssertEqual(people().suggestions(for: "DA").map(\.handle), ["DarioAmodei"])
        XCTAssertEqual(people().suggestions(for: "zz").map(\.handle), [])
    }

    func testSuggestionsMatchAnyWordOfTheNameLikeXDoes() {
        // "patel" is nobody's handle. It is Dwarkesh's surname.
        XCTAssertEqual(people().suggestions(for: "patel").map(\.handle), ["dwarkesh_sp"])
        XCTAssertEqual(people().suggestions(for: "andrej").map(\.handle), ["karpathy"])
        // A handle match comes before a name match: "pat" starts patrickc and Patel.
        XCTAssertEqual(people().suggestions(for: "pat").map(\.handle), ["patrickc", "dwarkesh_sp"])
        // A name typed without its space still finds the person.
        XCTAssertEqual(people().suggestions(for: "tylerc").map(\.handle), ["tylercowen"])
    }

    func testBareAtOffersTheMostLikelyPeople() {
        XCTAssertEqual(people().suggestions(for: "", limit: 3).map(\.handle), ["karpathy", "tylercowen", "dwarkesh_sp"])
    }

    func testSomeoneTaggedHereBeforeLeads() {
        var book = people()
        book.save(text: "thanks @patrickc", now: t0)
        XCTAssertEqual(book.suggestions(for: "", limit: 2).map(\.handle), ["patrickc", "karpathy"])
        XCTAssertEqual(book.suggestions(for: "pat").map(\.handle), ["patrickc", "dwarkesh_sp"])
    }

    func testAFinishedHandleShowsWhoItIs() {
        let found = people().suggestions(for: "karpathy")
        XCTAssertEqual(found.first?.name, "Andrej Karpathy")
    }

    func testAnUnknownHandleTypedHereIsRemembered() {
        var book = people()
        book.save(text: "hi @someone_new", now: t0)
        XCTAssertEqual(book.suggestions(for: "someone").map(\.handle), ["someone_new"])
    }

    func testImportKeepsWhatWasKnownAndCountsOnlyNewPeople() {
        var book = DraftBook()
        book.save(text: "@Karpathy", now: t0)
        let added = book.merge([
            Person(handle: "karpathy", name: "Andrej Karpathy", visits: 40),
            Person(handle: "tylercowen", name: "Tyler Cowen", visits: 30),
        ])
        XCTAssertEqual(added, 1)
        XCTAssertEqual(book.people.count, 2)
        let karpathy = book.people.first { $0.id == "karpathy" }
        XCTAssertEqual(karpathy?.name, "Andrej Karpathy")
        XCTAssertEqual(karpathy?.visits, 40)
        XCTAssertEqual(karpathy?.lastUsed, t0)
        // Importing again changes nothing.
        XCTAssertEqual(book.merge([Person(handle: "tylercowen", name: "Tyler Cowen", visits: 30)]), 0)
    }

    // MARK: Reading profiles out of browser history

    func testAProfilePageGivesHandleAndName() {
        let person = XProfilePage.person(url: "https://x.com/karpathy", title: "Andrej Karpathy (@karpathy) / X", visits: 7)
        XCTAssertEqual(person, Person(handle: "karpathy", name: "Andrej Karpathy", visits: 7))
    }

    func testOlderAndNoisierTitlesStillRead() {
        XCTAssertEqual(
            XProfilePage.person(url: "https://twitter.com/tylercowen", title: "(3) Tyler Cowen (@tylercowen) / Twitter", visits: 2)?.name,
            "Tyler Cowen")
        XCTAssertEqual(
            XProfilePage.person(url: "https://www.x.com/DarioAmodei?lang=en", title: "(20+) Dario Amodei (@DarioAmodei) / X", visits: 1)?.name,
            "Dario Amodei")
        XCTAssertEqual(
            XProfilePage.person(url: "https://x.com/someone", title: "Name (with) brackets (@someone) / X", visits: 1)?.name,
            "Name (with) brackets")
    }

    func testPagesThatAreNotProfilesAreSkipped() {
        XCTAssertNil(XProfilePage.person(url: "https://x.com/home", title: "Home / X", visits: 900))
        XCTAssertNil(XProfilePage.person(url: "https://x.com/karpathy/status/123", title: "Andrej Karpathy on X: \"...\" / X", visits: 3))
        XCTAssertNil(XProfilePage.person(url: "https://x.com/search?q=karpathy", title: "karpathy - Search / X", visits: 3))
        XCTAssertNil(XProfilePage.person(url: "https://x.com/karpathy", title: "X", visits: 3))
        XCTAssertNil(XProfilePage.person(url: "https://example.com/karpathy", title: "Andrej Karpathy (@karpathy) / X", visits: 3))
        XCTAssertNil(XProfilePage.person(url: "https://x.com/this_handle_is_too_long", title: "A (@this_handle_is_too_long) / X", visits: 1))
    }

    func testVisitsToTheSameProfileAddUp() {
        let people = XProfilePage.people(from: [
            (url: "https://x.com/karpathy", title: "Andrej Karpathy (@karpathy) / X", visits: 5),
            (url: "https://twitter.com/karpathy", title: "Andrej Karpathy (@karpathy) / Twitter", visits: 4),
            (url: "https://x.com/tylercowen", title: "Tyler Cowen (@tylercowen) / X", visits: 20),
            (url: "https://x.com/home", title: "Home / X", visits: 999),
        ])
        XCTAssertEqual(people.map(\.handle), ["tylercowen", "karpathy"])
        XCTAssertEqual(people.map(\.visits), [20, 9])
    }

    // MARK: Adding images in X

    func testLocateOutputIsRead() {
        XCTAssertEqual(
            ComposeAttach.parseLocate("2102722175\t2102722176\tjs\t1\t0\n"),
            ComposeAttach.Target(window: 2102722175, tab: 2102722176, canLook: true, boxFound: true, alreadyAttached: 0))
        XCTAssertEqual(
            ComposeAttach.parseLocate("7\t9\tnojs\t0\t0"),
            ComposeAttach.Target(window: 7, tab: 9, canLook: false, boxFound: false, alreadyAttached: 0))
        // No tab turned up, or the script said something unexpected.
        XCTAssertNil(ComposeAttach.parseLocate(""))
        XCTAssertNil(ComposeAttach.parseLocate("7\t9\tjs"))
        XCTAssertNil(ComposeAttach.parseLocate("7\t9\tmaybe\t1\t0"))
    }

    func testPasteIsCountedAgainstWhatWasAlreadyThere() {
        let empty = ComposeAttach.Target(window: 1, tab: 2, canLook: true, boxFound: true, alreadyAttached: 0)
        XCTAssertEqual(ComposeAttach.parsePaste("2", target: empty), .attached(2))
        XCTAssertEqual(ComposeAttach.parsePaste("0", target: empty), .attached(0))
        let oneThere = ComposeAttach.Target(window: 1, tab: 2, canLook: true, boxFound: true, alreadyAttached: 1)
        XCTAssertEqual(ComposeAttach.parsePaste("2\n", target: oneThere), .attached(1))
        XCTAssertEqual(ComposeAttach.parsePaste("1", target: oneThere), .attached(0))
    }

    func testPasteThatCannotBeCheckedIsNotCalledAttached() {
        let blind = ComposeAttach.Target(window: 1, tab: 2, canLook: false, boxFound: false, alreadyAttached: 0)
        XCTAssertEqual(ComposeAttach.parsePaste("pasted", target: blind), .pasted)
        // The page could be read but X's box wasn't recognised, so a count of
        // nothing proves nothing.
        let unrecognised = ComposeAttach.Target(window: 1, tab: 2, canLook: true, boxFound: false, alreadyAttached: 0)
        XCTAssertEqual(ComposeAttach.parsePaste("0", target: unrecognised), .pasted)
    }

    func testScriptsNameTheTabAndNeverLookWhereTheyMayNot() {
        let address = TweetText.composeURL(for: "it's \"quoted\" \\ done")!.absoluteString
        let locate = ComposeAttach.locateScript(bundleID: "com.google.Chrome", address: address)
        XCTAssertTrue(locate.contains("whose URL is \"\(address)\""))
        // The address is percent-encoded, so nothing in it can end the string.
        XCTAssertFalse(address.contains("\""))
        let blind = ComposeAttach.Target(window: 11, tab: 22, canLook: false, boxFound: false, alreadyAttached: 0)
        let paste = ComposeAttach.pasteScript(bundleID: "com.google.Chrome", target: blind, expecting: 1)
        XCTAssertTrue(paste.contains("whose id is 11"))
        XCTAssertTrue(paste.contains("whose id is 22"))
        XCTAssertTrue(paste.contains("paste selection"))
        XCTAssertFalse(paste.contains("javascript"))
    }
}

import JavaScriptCore
import XCTest
@testable import FocusGuardCore

final class PolicyTests: XCTestCase {
    func testRuleNormalisesWhatPeopleType() {
        XCTAssertEqual(SiteRule("https://www.X.com/")?.text, "x.com")
        XCTAssertEqual(SiteRule("*.linkedin.com")?.text, "linkedin.com")
        XCTAssertEqual(SiteRule("linkedin.com/feed/")?.text, "linkedin.com/feed")
        XCTAssertEqual(SiteRule("localhost:3000")?.text, "localhost")
        XCTAssertEqual(SiteRule("mail.google.com/mail/u/0/#inbox")?.text, "mail.google.com/mail/u/0")
    }

    func testRuleRejectsWhatIsNotASite() {
        XCTAssertNil(SiteRule(""))
        XCTAssertNil(SiteRule("discord"))
        XCTAssertNil(SiteRule("not a site"))
        XCTAssertNil(SiteRule(".com"))
    }

    func testBlockListCoversSubdomainsOnly() {
        let policy = SitePolicy(mode: .block, entries: ["x.com", "linkedin.com"])
        XCTAssertTrue(policy.blocks("https://x.com/home"))
        XCTAssertTrue(policy.blocks("https://www.linkedin.com/feed/"))
        XCTAssertTrue(policy.blocks("http://mobile.x.com"))
        XCTAssertFalse(policy.blocks("https://netflix.com"))
        XCTAssertFalse(policy.blocks("https://notx.com"))
        XCTAssertFalse(policy.blocks("https://example.com/?next=x.com"))
    }

    func testAliasesReachTheHostTheServiceLivesOn() {
        let policy = SitePolicy(mode: .block, entries: ["gmail.com", "x.com"])
        XCTAssertTrue(policy.blocks("https://mail.google.com/mail/u/0/#inbox"))
        XCTAssertTrue(policy.blocks("https://twitter.com/home"))
        XCTAssertFalse(policy.blocks("https://docs.google.com/document/d/1"))
        XCTAssertFalse(policy.blocks("https://www.google.com/search?q=gmail"))
    }

    func testPathRuleLeavesTheRestOfTheSiteAlone() {
        let policy = SitePolicy(mode: .block, entries: ["linkedin.com/feed"])
        XCTAssertTrue(policy.blocks("https://www.linkedin.com/feed/"))
        XCTAssertTrue(policy.blocks("https://www.linkedin.com/feed/update/123"))
        XCTAssertFalse(policy.blocks("https://www.linkedin.com/feedback"))
        XCTAssertFalse(policy.blocks("https://www.linkedin.com/in/someone"))
    }

    func testAllowListBlocksEverythingElseOnTheWeb() {
        let policy = SitePolicy(mode: .allow, entries: ["arxiv.org", "docs.google.com"])
        XCTAssertFalse(policy.blocks("https://arxiv.org/abs/2401.00001"))
        XCTAssertFalse(policy.blocks("https://docs.google.com/document/d/1"))
        XCTAssertTrue(policy.blocks("https://x.com"))
        XCTAssertTrue(policy.blocks("https://mail.google.com"))
    }

    func testBrowserPagesAndLocalFilesAlwaysPass() {
        let policy = SitePolicy(mode: .allow, entries: [])
        XCTAssertTrue(policy.blocks("https://example.com"))
        XCTAssertFalse(policy.blocks("chrome://newtab/"))
        XCTAssertFalse(policy.blocks("about:blank"))
        XCTAssertFalse(policy.blocks("file:///Users/me/blocked.html#x.com"))
        XCTAssertFalse(policy.blocks(""))
    }

    func testEmptyBlockListDoesNothing() {
        let policy = SitePolicy(mode: .block, entries: [])
        XCTAssertFalse(policy.isActive)
        XCTAssertFalse(policy.blocks("https://x.com"))
    }

    func testParseSplitsAPastedList() {
        XCTAssertEqual(
            SitePolicy.parse("x.com, https://www.linkedin.com/\nnot-a-site discord.com"),
            ["x.com", "linkedin.com", "discord.com"])
    }

    func testAppBlockList() {
        let policy = AppPolicy(mode: .block, bundleIDs: ["com.hnc.Discord"])
        XCTAssertTrue(policy.blocks("com.hnc.Discord"))
        XCTAssertFalse(policy.blocks("com.apple.Safari"))
    }

    func testAppAllowListSparesExemptApps() {
        let policy = AppPolicy(mode: .allow, bundleIDs: ["com.apple.Safari"], exempt: ["com.apple.finder"])
        XCTAssertFalse(policy.blocks("com.apple.Safari"))
        XCTAssertFalse(policy.blocks("com.apple.finder"))
        XCTAssertTrue(policy.blocks("com.hnc.Discord"))
    }

    func testConfigRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("config.json")
        let config = Config(profiles: [
            Profile(name: "Deep", siteMode: .allow, sites: ["arxiv.org"],
                    apps: [AppRef(bundleID: "com.hnc.Discord", name: "Discord")], cooldownSeconds: 90)
        ])
        try ConfigStore.save(config, to: url)
        XCTAssertEqual(ConfigStore.load(from: url), config)
        XCTAssertEqual(ConfigStore.load(from: url.appendingPathExtension("missing")), Config())
    }

    func testNetworkHostsAreWholeHostsFromABlockList() {
        let block = SitePolicy(mode: .block, entries: ["x.com", "linkedin.com/feed", "gmail.com"])
        XCTAssertEqual(block.networkHosts, ["x.com", "twitter.com", "gmail.com", "mail.google.com"])
        XCTAssertEqual(SitePolicy(mode: .allow, entries: ["arxiv.org"]).networkHosts, [])
    }

    /// Runs the generated file the way a browser would.
    func testProxyAutoConfigRefusesListedHostsOnly() throws {
        let source = ProxyAutoConfig.source(blocking: ["x.com", "mail.google.com"], via: "127.0.0.1:47113")
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(source)
        func route(_ host: String) -> String {
            context.evaluateScript("FindProxyForURL('https://\(host)/', '\(host)')").toString()
        }
        XCTAssertEqual(route("x.com"), "PROXY 127.0.0.1:47113")
        XCTAssertEqual(route("www.x.com"), "PROXY 127.0.0.1:47113")
        XCTAssertEqual(route("API.X.COM"), "PROXY 127.0.0.1:47113")
        XCTAssertEqual(route("mail.google.com"), "PROXY 127.0.0.1:47113")
        XCTAssertEqual(route("notx.com"), "DIRECT")
        XCTAssertEqual(route("x.com.evil.example"), "DIRECT")
        XCTAssertEqual(route("docs.google.com"), "DIRECT")
        XCTAssertEqual(route("com"), "DIRECT")
    }

    func testProxyAutoConfigWithNothingListedLetsEverythingThrough() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(ProxyAutoConfig.source(blocking: [], via: "127.0.0.1:47113"))
        XCTAssertEqual(context.evaluateScript("FindProxyForURL('https://x.com/', 'x.com')").toString(), "DIRECT")
    }
}

import XCTest
@testable import PageCaptureCore

/// The cookies and Referer sent for a page's subresources, as a browser would (SPEC "Saving").
final class BrowserRequestTests: XCTestCase {
    private func cookie(_ name: String, domain: String = ".site.test", sameSite: String? = nil) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.domain: domain, .path: "/", .name: name, .value: "1"]
        if let sameSite { properties[.sameSitePolicy] = sameSite }
        return HTTPCookie(properties: properties)!
    }

    private var jar: [HTTPCookie] {
        [cookie("lax", sameSite: "lax"), cookie("strict", sameSite: "strict"), cookie("unset"),
         cookie("none", sameSite: "none"), cookie("elsewhere", domain: "other.test", sameSite: "none")]
    }

    private func names(page: String, url: String) -> [String] {
        let url = URL(string: url)!
        return BrowserRequest(page: URL(string: page), cookies: jar).cookies(for: url, first: url).map(\.name).sorted()
    }

    func testSameSiteRequestsGetAllTheirCookies() {
        XCTAssertEqual(names(page: "https://www.site.test/a/page.html", url: "https://cdn.site.test/x.png"),
                       ["lax", "none", "strict", "unset"])
    }

    /// A cookie without a SameSite policy counts as Lax. (WebKit's cookie store reports cookies set
    /// without the attribute as `none`, so those are sent, as WebKit itself does.)
    func testCrossSiteRequestsGetOnlySameSiteNoneCookies() {
        XCTAssertEqual(names(page: "https://www.other.test/page.html", url: "https://cdn.site.test/x.png"), ["none"])
        let request = BrowserRequest(page: URL(string: "https://www.other.test/page.html"), cookies: jar)
            .request(URL(string: "https://cdn.site.test/x.png")!)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "none=1")
    }

    func testWithoutAPageTheFirstURLDecidesTheSite() {
        let browser = BrowserRequest(page: nil, cookies: jar)
        let first = URL(string: "https://www.site.test/doc.pdf")!
        XCTAssertEqual(browser.cookies(for: URL(string: "https://cdn.site.test/doc.pdf")!, first: first).count, 4)
        XCTAssertEqual(browser.cookies(for: URL(string: "https://cdn.site.test/doc.pdf")!,
                                       first: URL(string: "https://other.test/")!).map(\.name), ["none"])
        XCTAssertNil(browser.request(first).value(forHTTPHeaderField: "Referer"))
    }

    /// Without the Public Suffix List: the last two labels, the whole host for IP addresses.
    func testTheSiteIsTheHostsLastTwoLabels() {
        XCTAssertEqual(BrowserRequest.site(of: "a.b.Site.test"), "site.test")
        XCTAssertEqual(BrowserRequest.site(of: "site.test"), "site.test")
        XCTAssertEqual(BrowserRequest.site(of: "localhost"), "localhost")
        XCTAssertEqual(BrowserRequest.site(of: "127.0.0.1"), "127.0.0.1")
        XCTAssertEqual(BrowserRequest.site(of: "::1"), "::1")
        XCTAssertEqual(BrowserRequest.site(of: "a.example.co.uk"), "co.uk", "the documented limitation")
    }

    func testRefererIsThePageSameOriginItsOriginCrossOriginAndNoneFromHTTPSToHTTP() {
        let browser = BrowserRequest(page: URL(string: "https://www.site.test/a/page.html?q=1#part"), cookies: [])
        XCTAssertEqual(browser.referer(for: URL(string: "https://www.site.test/img.png")!), "https://www.site.test/a/page.html?q=1")
        XCTAssertEqual(browser.referer(for: URL(string: "https://www.site.test:443/img.png")!), "https://www.site.test/a/page.html?q=1")
        XCTAssertEqual(browser.referer(for: URL(string: "https://cdn.site.test/img.png")!), "https://www.site.test/")
        XCTAssertEqual(browser.referer(for: URL(string: "https://other.test/img.png")!), "https://www.site.test/")
        XCTAssertNil(browser.referer(for: URL(string: "http://www.site.test/img.png")!))
        let local = BrowserRequest(page: URL(string: "http://127.0.0.1:8080/p.html"), cookies: [])
        XCTAssertEqual(local.referer(for: URL(string: "http://localhost:8080/x")!), "http://127.0.0.1:8080/")
        XCTAssertEqual(local.referer(for: URL(string: "https://127.0.0.1:8080/x")!), "http://127.0.0.1:8080/")
    }
}

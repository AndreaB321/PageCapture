import XCTest
@testable import PageCaptureCore

final class CapturedContentTests: XCTestCase {
    func testDecodesCollectorJSON() throws {
        let json = """
        {"html":"<p>Hi</p>","imageURLs":["https://a.test/1.png","https://a.test/2.png"],"stopped":false,
         "baseURL":"https://a.test/page","title":"Page",
         "stylesheets":[{"href":"https://a.test/s.css"},{"css":"p{color:red}"}],
         "videos":[{"index":0,"kind":"hls","url":"https://a.test/v|1.m3u8","pageURL":"https://a.test/page",
                    "frameOrigin":"https://a.test","posterURL":"https://a.test/1.png","title":"Clip"},
                   {"index":1,"kind":"youtube","url":"https://www.youtube.com/embed/x","pageURL":"https://a.test/page",
                    "frameOrigin":"https://a.test","posterURL":null,"title":null}]}
        """
        let content = try CapturedContent(collectorJSON: json)
        XCTAssertEqual(content, CapturedContent(
            html: "<p>Hi</p>",
            baseURL: URL(string: "https://a.test/page")!,
            title: "Page",
            stylesheets: [.link(URL(string: "https://a.test/s.css")!), .inline("p{color:red}")],
            imageURLs: ["https://a.test/1.png", "https://a.test/2.png"],
            videos: [
                CapturedVideo(index: 0, kind: .hls, url: "https://a.test/v|1.m3u8", pageURL: "https://a.test/page",
                              frameOrigin: "https://a.test", posterURL: "https://a.test/1.png", title: "Clip"),
                CapturedVideo(index: 1, kind: .youtube, url: "https://www.youtube.com/embed/x",
                              pageURL: "https://a.test/page", frameOrigin: "https://a.test"),
            ]
        ))
    }

    func testDecodesAncestorShells() throws {
        let json = """
        {"html":"<p>Hi</p>","imageURLs":[],"baseURL":"https://a.test/","title":"","stylesheets":[],"videos":[],
         "ancestors":[{"tag":"html","attributes":{"class":"theme-x","lang":"en"}},{"tag":"body","attributes":{}},
                      {"tag":"article","attributes":{"class":"col"}}]}
        """
        XCTAssertEqual(try CapturedContent(collectorJSON: json).ancestors, [
            ElementShell(tag: "html", attributes: ["class": "theme-x", "lang": "en"]),
            ElementShell(tag: "body"),
            ElementShell(tag: "article", attributes: ["class": "col"]),
        ])
    }

    /// JSON from a collector that did not record shells still decodes, with no ancestors.
    func testDecodesCollectorJSONWithoutAncestors() throws {
        let json = #"{"html":"<p>Hi</p>","imageURLs":[],"baseURL":"https://a.test/","title":"","stylesheets":[],"videos":[]}"#
        XCTAssertEqual(try CapturedContent(collectorJSON: json).ancestors, [])
    }

    func testRejectsMissingBaseURL() {
        let json = #"{"html":"","imageURLs":[],"baseURL":"","title":"","stylesheets":[],"videos":[]}"#
        XCTAssertThrowsError(try CapturedContent(collectorJSON: json))
    }
}

final class AddressInputTests: XCTestCase {
    func testKeepsURLsWithAWebScheme() {
        XCTAssertEqual(AddressInput.url(from: " https://example.com/a?b=1 "), URL(string: "https://example.com/a?b=1"))
        XCTAssertEqual(AddressInput.url(from: "http://localhost:8080"), URL(string: "http://localhost:8080"))
    }

    func testAddsHTTPSToBareHosts() {
        XCTAssertEqual(AddressInput.url(from: "example.com/path"), URL(string: "https://example.com/path"))
        XCTAssertEqual(AddressInput.url(from: "localhost:3000"), URL(string: "https://localhost:3000"))
    }

    func testRejectsEmptyOrSpacedInput() {
        XCTAssertNil(AddressInput.url(from: "   "))
        XCTAssertNil(AddressInput.url(from: "two words"))
    }
}

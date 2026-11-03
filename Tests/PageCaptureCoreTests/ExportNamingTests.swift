import XCTest
@testable import PageCaptureCore

final class ExportNamingTests: XCTestCase {
    func testSanitizedNameReplacesSeparatorsAndCollapsesWhitespace() {
        XCTAssertEqual(ExportNaming.sanitizedName(fromTitle: "  Q3: Plans / Notes\n\tdraft  "), "Q3- Plans - Notes draft")
        XCTAssertEqual(ExportNaming.sanitizedName(fromTitle: "a\u{0}b\\c"), "a-b-c")
    }

    func testSanitizedNameTrimsDotsAndFallsBack() {
        XCTAssertEqual(ExportNaming.sanitizedName(fromTitle: "..hidden."), "hidden")
        XCTAssertEqual(ExportNaming.sanitizedName(fromTitle: "   "), "Capture")
        XCTAssertEqual(ExportNaming.sanitizedName(fromTitle: ""), "Capture")
    }

    func testSanitizedNameIsCapped() {
        XCTAssertEqual(ExportNaming.sanitizedName(fromTitle: String(repeating: "x", count: 300)).count, 100)
    }

    func testImageFileNameKeepsURLBasenameAndExtension() {
        let url = URL(string: "https://cdn.example.com/a/b/Photo%20One.JPG?w=200")!
        XCTAssertEqual(ExportNaming.imageFileName(index: 0, url: url, mimeType: "image/png"), "001-Photo-One.jpg")
    }

    func testImageFileNameTakesExtensionFromMIMEWhenURLHasNone() {
        let url = URL(string: "https://example.com/render.php?id=4")!
        XCTAssertEqual(ExportNaming.imageFileName(index: 11, url: url, mimeType: "image/jpeg; charset=binary"), "012-render.jpg")
        let bare = URL(string: "https://example.com/avatar")!
        XCTAssertEqual(ExportNaming.imageFileName(index: 1, url: bare, mimeType: "image/webp"), "002-avatar.webp")
        XCTAssertEqual(ExportNaming.imageFileName(index: 2, url: bare, mimeType: "image/svg+xml"), "003-avatar.svg")
        XCTAssertEqual(ExportNaming.imageFileName(index: 3, url: bare, mimeType: nil), "004-avatar.img")
    }

    func testImageFileNameForRootAndDataURLs() {
        XCTAssertEqual(ExportNaming.imageFileName(index: 0, url: URL(string: "https://example.com/")!, mimeType: "image/gif"),
                       "001-image.gif")
        let data = URL(string: "data:image/png;base64,iVBORw0KGgo=")!
        XCTAssertEqual(ExportNaming.imageFileName(index: 999, url: data, mimeType: "image/png"), "1000-image.png")
    }

    func testRelativeImagePath() {
        XCTAssertEqual(ExportNaming.relativeImagePath("001-a.png"), "images/001-a.png")
    }

    func testDataURLDecodesBase64AndPercentEncoded() throws {
        let png = try XCTUnwrap(DataURL.decode("data:image/png;base64,aGVsbG8"))
        XCTAssertEqual(png.mimeType, "image/png")
        XCTAssertEqual(png.data, Data("hello".utf8))
        let svg = try XCTUnwrap(DataURL.decode("data:image/svg+xml;charset=utf-8,%3Csvg%2F%3E"))
        XCTAssertEqual(svg.mimeType, "image/svg+xml")
        XCTAssertEqual(String(decoding: svg.data, as: UTF8.self), "<svg/>")
        XCTAssertEqual(DataURL.decode("data:,hi")?.mimeType, "text/plain")
        XCTAssertNil(DataURL.decode("https://example.com/a.png"))
        XCTAssertNil(DataURL.decode("data:image/png;base64"))
    }

    func testPaperSizeByRegion() {
        XCTAssertEqual(PaperSize.forRegion("US"), .letter)
        XCTAssertEqual(PaperSize.forRegion("CA"), .letter)
        XCTAssertEqual(PaperSize.forRegion("MX"), .letter)
        XCTAssertEqual(PaperSize.forRegion("GB"), .a4)
        XCTAssertEqual(PaperSize.forRegion("IT"), .a4)
        XCTAssertEqual(PaperSize.forRegion(nil), .a4)
    }

    func testVideoFileStemHasNoURLSpecialCharacters() {
        let stem = ExportNaming.videoFileStem(index: 0, title: "Lesson #2: Setup? 100% (part 1)", url: "https://x.test/v.mp4")
        XCTAssertEqual(stem, "001-Lesson -2- Setup- 100- (part 1)")
        for c in ["#", "?", "%"] { XCTAssertFalse(stem.contains(c), stem) }
        let image = ExportNaming.imageFileName(index: 0, url: URL(string: "https://x.test/a%23b%3Fc%25d.png")!, mimeType: nil)
        for c in ["#", "?", "%"] { XCTAssertFalse(image.contains(c), image) }
    }
}

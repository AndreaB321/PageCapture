import ImageIO
import XCTest
@testable import PageCaptureCore

final class ImageDownloaderTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ImageDownloaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        FixtureURLProtocol.reset()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testDownloadsInOrderWithStableNamesAndSkipsFailures() async throws {
        let urls = [
            "https://images.test/pics/cat.png",
            "https://images.test/pics/missing.png",
            "data:image/gif;base64,R0lGODlhAQABAAAAACw=",
            "https://images.test/pics/login.jpg",
            "https://images.test/pics/noext",
        ]
        let result = await ImageDownloader.download(
            urls, into: folder, referer: URL(string: "https://site.test/page")!, cookies: [],
            configuration: FixtureURLProtocol.configuration())

        XCTAssertEqual(result.files, [
            urls[0]: "001-cat.png",
            urls[2]: "003-image.gif",
            urls[4]: "005-noext.jpg",
        ])
        XCTAssertEqual(result.failed, [urls[1], urls[3]])
        XCTAssertEqual(result.relativePaths["https://images.test/pics/cat.png"], "images/001-cat.png")
        let written = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(written, ["001-cat.png", "003-image.gif", "005-noext.jpg"])
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("001-cat.png")), FixtureURLProtocol.png)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("003-image.gif")).prefix(6), Data("GIF89a".utf8))
    }

    func testConvertsAVIFAndWebPToPNGAndKeepsPortableFormats() async throws {
        let urls = [
            "https://images.test/pics/hero.avif",
            "https://images.test/pics/photo.webp",
            "https://images.test/pics/noext",
            "https://images.test/pics/cat.png",
        ]
        let result = await ImageDownloader.download(
            urls, into: folder, referer: URL(string: "https://site.test/page")!, cookies: [],
            configuration: FixtureURLProtocol.configuration())

        XCTAssertEqual(result.files, [
            urls[0]: "001-hero.png", urls[1]: "002-photo.png", urls[2]: "003-noext.jpg", urls[3]: "004-cat.png",
        ])
        XCTAssertEqual(result.failed, [])
        XCTAssertEqual(result.relativePaths[urls[0]], "images/001-hero.png")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(),
                       ["001-hero.png", "002-photo.png", "003-noext.jpg", "004-cat.png"])
        for name in ["001-hero.png", "002-photo.png"] {
            let data = try Data(contentsOf: folder.appendingPathComponent(name))
            XCTAssertEqual(data.prefix(8), Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), name)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.png", name)
            XCTAssertNotNil(CGImageSourceCreateImageAtIndex(source, 0, nil), name)
        }
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("004-cat.png")), FixtureURLProtocol.png)
    }

    func testUndecodableAVIFKeepsItsOriginalFile() async throws {
        // A body that is not an image at all is saved as downloaded, under its own extension.
        let result = await ImageDownloader.download(
            ["data:image/avif;base64,AAAA"], into: folder, referer: URL(string: "https://site.test/page")!,
            cookies: [], configuration: FixtureURLProtocol.configuration())
        XCTAssertEqual(result.files.values.first, "001-image.avif")
        XCTAssertEqual(result.failed, [])
    }

    func testSendsRefererAndBrowserCookies() async throws {
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "images.test", .path: "/", .name: "session", .value: "abc123", .secure: "TRUE",
        ]))
        _ = await ImageDownloader.download(
            ["https://images.test/private/a.png"], into: folder,
            referer: URL(string: "https://site.test/page")!, cookies: [cookie],
            configuration: FixtureURLProtocol.configuration())

        let request = try XCTUnwrap(FixtureURLProtocol.requests.first)
        XCTAssertEqual(request.referer, "https://site.test/page")
        XCTAssertEqual(request.cookie, "session=abc123")
    }
}

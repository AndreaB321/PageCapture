import XCTest
@testable import PageCaptureCore

final class DocumentDownloaderTests: XCTestCase {
    private var folder: URL!
    private let page = URL(string: "https://site.test/reports/page.html")!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("DocumentDownloaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        FixtureURLProtocol.reset()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func source(_ name: String, _ kind: DocumentKind) -> DocumentSource {
        DocumentSource(url: URL(string: "https://documents.test/\(name)")!, kind: kind)
    }

    private func download(_ source: DocumentSource, cookies: [HTTPCookie] = [],
                          maxBytes: Int = DocumentDownloader.maxBytes) async throws -> DownloadedDocument {
        try await DocumentDownloader.download(source, referer: page, cookies: cookies,
                                              configuration: FixtureURLProtocol.configuration(),
                                              maxBytes: maxBytes, temporaryRoot: folder)
    }

    private func error(downloading source: DocumentSource, maxBytes: Int = DocumentDownloader.maxBytes) async -> Error? {
        do {
            _ = try await download(source, maxBytes: maxBytes)
            return nil
        } catch {
            return error
        }
    }

    private func assertNothingLeft(file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [], file: file, line: line)
    }

    func testDownloadsEachKindUnchangedWithCookieAndReferer() async throws {
        let cookie = HTTPCookie(properties: [.domain: "documents.test", .path: "/", .name: "session", .value: "s3cret"])!
        let other = HTTPCookie(properties: [.domain: "elsewhere.test", .path: "/", .name: "other", .value: "x"])!
        for (name, kind) in [("text.pdf", DocumentKind.pdf), ("document.docx", .docx), ("slides.pptx", .pptx),
                             ("sheet.xlsx", .xlsx)] {
            let downloaded = try await download(source(name, kind), cookies: [cookie, other])
            XCTAssertEqual(downloaded.source, source(name, kind))
            XCTAssertEqual(downloaded.file.lastPathComponent, "original.\(kind.rawValue)")
            let fixture = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/documents/\(name)", withExtension: nil))
            XCTAssertEqual(try Data(contentsOf: downloaded.file), try Data(contentsOf: fixture), name)
            XCTAssertEqual(FixtureURLProtocol.requests.last?.referer, page.absoluteString)
            XCTAssertEqual(FixtureURLProtocol.requests.last?.cookie, "session=s3cret")
            downloaded.discard()
        }
        try assertNothingLeft()
    }

    func testASignInPageIsNotADocument() async throws {
        let failure = await error(downloading: source("login.pdf", .pdf))
        XCTAssertEqual(failure as? DocumentDownloadError, .notADocument)
        try assertNothingLeft()
    }

    func testAFileOfAnotherKindIsNotADocument() async throws {
        let zip = await error(downloading: source("text.pdf", .docx))
        XCTAssertEqual(zip as? DocumentDownloadError, .notADocument)
        let ole = await error(downloading: source("document.docx", .xls))
        XCTAssertEqual(ole as? DocumentDownloadError, .notADocument)
        try assertNothingLeft()
    }

    func testHTTPErrorsAreReportedWithTheirStatus() async throws {
        let failure = await error(downloading: source("missing.pdf", .pdf))
        XCTAssertEqual(failure as? DocumentDownloadError, .httpStatus(404))
        try assertNothingLeft()
    }

    func testDownloadStopsOverTheSizeLimit() async throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/documents/text.pdf", withExtension: nil))
        let size = try Data(contentsOf: fixture).count
        let failure = await error(downloading: source("text.pdf", .pdf), maxBytes: size - 1)
        XCTAssertEqual(failure as? DocumentDownloadError, .tooLarge)
        try assertNothingLeft()
        let exact = try await download(source("text.pdf", .pdf), maxBytes: size)
        XCTAssertEqual(try Data(contentsOf: exact.file).count, size)
    }
}

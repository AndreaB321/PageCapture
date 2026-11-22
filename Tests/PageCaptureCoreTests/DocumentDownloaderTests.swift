import XCTest
@testable import PageCaptureCore

final class DocumentDownloaderTests: XCTestCase {
    private var folder: URL!
    private let page = URL(string: "https://documents.test/reports/page.html")!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("DocumentDownloaderTests-\(UUID().uuidString)")
        try VideoDownloader.makePrivateDirectory(folder)
        FixtureURLProtocol.reset()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func source(_ name: String, _ kind: DocumentKind) -> DocumentSource {
        DocumentSource(url: URL(string: "https://documents.test/\(name)")!, kind: kind)
    }

    private func download(_ source: DocumentSource, page: URL? = nil, cookies: [HTTPCookie] = [],
                          maxBytes: Int = DocumentDownloader.maxBytes) async throws -> DownloadedDocument {
        try await DocumentDownloader.download(source, referer: page ?? self.page, cookies: cookies,
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

    // MARK: Redirects and cookies (SPEC "Saving")

    private func cookie(_ name: String, domain: String = "documents.test", path: String = "/",
                        secure: Bool = false, sameSite: String? = nil) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.domain: domain, .path: path, .name: name, .value: "1"]
        if secure { properties[.secure] = "TRUE" }
        if let sameSite { properties[.sameSitePolicy] = sameSite }
        return HTTPCookie(properties: properties)!
    }

    private func redirect(_ from: String, to target: String) -> URL {
        var components = URLComponents(string: from)!
        components.queryItems = [URLQueryItem(name: "to", value: target)]
        return components.url!
    }

    /// Against a real server, as URLSession's own redirect handling is what copied hand-set headers:
    /// 127.0.0.1 redirects to localhost, another host and site.
    func testARedirectToAnotherHostGetsNoneOfTheFirstHostsCookies() async throws {
        let server = try await FixtureHTTPServer.start()
        defer { server.stop() }
        let pdf = try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/documents/text.pdf", withExtension: nil)))
        server.route("/files/report.pdf", pdf)
        server.redirect("/download", to: "http://localhost:\(server.port)/files/report.pdf")
        let page = try XCTUnwrap(URL(string: server.url("/page.html")))
        let session = HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/", .name: "session", .value: "SECRET"])!

        let downloaded = try await download(DocumentSource(url: try XCTUnwrap(URL(string: server.url("/download"))), kind: .pdf),
                                            page: page, cookies: [session])
        XCTAssertEqual(try Data(contentsOf: downloaded.file), pdf)
        let requests = server.requests
        XCTAssertEqual(requests.map(\.path), ["/download", "/files/report.pdf"])
        XCTAssertEqual(requests.first?.headers["cookie"], "session=SECRET")
        XCTAssertEqual(requests.first?.headers["referer"], page.absoluteString)
        XCTAssertEqual(requests.last?.headers["host"], "localhost:\(server.port)")
        XCTAssertNil(requests.last?.headers["cookie"])
        XCTAssertEqual(requests.last?.headers["referer"], "http://127.0.0.1:\(server.port)/", "origin only, cross-origin")
    }

    func testAnHTTPSToHTTPRedirectSendsNoCookiesAndNoReferer() async throws {
        let source = DocumentSource(url: redirect("https://documents.test/redirect", to: "http://documents.test/text.pdf"), kind: .pdf)
        _ = try await download(source, cookies: [cookie("plain"), cookie("secure", secure: true)])
        let requests = FixtureURLProtocol.requests
        XCTAssertEqual(requests.map(\.url.scheme), ["https", "http"])
        XCTAssertEqual(requests.first?.cookie?.split(separator: ";").count, 2)
        XCTAssertEqual(requests.first?.referer, page.absoluteString)
        XCTAssertNil(requests.last?.cookie)
        XCTAssertNil(requests.last?.referer)
    }

    func testASameHostRedirectSendsTheCookiesOfTheNewURL() async throws {
        let source = DocumentSource(url: redirect("https://documents.test/redirect", to: "https://documents.test/reports/text.pdf"),
                                    kind: .pdf)
        _ = try await download(source, cookies: [cookie("site"), cookie("hop", path: "/redirect")])
        let requests = FixtureURLProtocol.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.first?.cookie.map { Set($0.components(separatedBy: "; ")) }, ["site=1", "hop=1"])
        XCTAssertEqual(requests.last?.cookie, "site=1")
        XCTAssertEqual(requests.last?.referer, page.absoluteString)
    }

    func testARedirectToAnotherSchemeIsRefused() async throws {
        let source = DocumentSource(url: redirect("https://documents.test/redirect", to: "pctest://images.test/a.pdf"), kind: .pdf)
        let failure = await error(downloading: source)
        // A real HTTP load ends with the 302 response; the fixture's redirect ends with an error.
        XCTAssertNotNil(failure)
        XCTAssertEqual(FixtureURLProtocol.requests.map(\.url.scheme), ["https"])
        try assertNothingLeft()
    }

    /// Cross-site with the page: no Lax or Strict cookies, and the page's origin as referer.
    func testACrossSiteDocumentGetsOnlySameSiteNoneCookies() async throws {
        let cookies = [cookie("unset", domain: "other.test"), cookie("lax", domain: "other.test", sameSite: "lax"),
                       cookie("none", domain: "other.test", sameSite: "none")]
        _ = try await download(DocumentSource(url: URL(string: "https://other.test/text.pdf")!, kind: .pdf), cookies: cookies)
        XCTAssertEqual(FixtureURLProtocol.requests.last?.cookie, "none=1; unset=1")
        XCTAssertEqual(FixtureURLProtocol.requests.last?.referer, "https://documents.test/")
    }

    // MARK: Temporary files

    /// In a private folder of PageCapture's temporary root, which launch and quit empty.
    func testTheOriginalWaitsInAPrivateFolderUnderThePageCaptureTemporaryRoot() async throws {
        let downloaded = try await DocumentDownloader.download(source("text.pdf", .pdf), referer: page, cookies: [],
                                                               configuration: FixtureURLProtocol.configuration())
        defer { downloaded.discard() }
        let work = downloaded.file.deletingLastPathComponent()
        XCTAssertEqual(work.deletingLastPathComponent().standardizedFileURL.path,
                       VideoDownloader.defaultTemporaryRoot.standardizedFileURL.path)
        func mode(_ url: URL) throws -> Int {
            try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
        }
        XCTAssertEqual(try mode(VideoDownloader.defaultTemporaryRoot), 0o700)
        XCTAssertEqual(try mode(work), 0o700)
        XCTAssertEqual(try mode(downloaded.file), 0o600)
        downloaded.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.path))
    }

    func testCancellingDuringTheDownloadRemovesItsFolder() async throws {
        let (stall, page, folder) = (source("stall.pdf", .pdf), page, folder!)
        let task = Task {
            try await DocumentDownloader.download(stall, referer: page, cookies: [],
                                                  configuration: FixtureURLProtocol.configuration(), temporaryRoot: folder)
        }
        let deadline = Date().addingTimeInterval(10)
        while (try FileManager.default.contentsOfDirectory(atPath: folder.path)).isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 1, "the download started")
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled download returned")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        try assertNothingLeft()
    }

    // MARK: Failures

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

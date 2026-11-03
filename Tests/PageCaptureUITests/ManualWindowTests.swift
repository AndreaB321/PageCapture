import AppKit
import WebKit
import XCTest
@testable import PageCaptureUI

@MainActor
final class ManualWindowTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManualWindowTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Location

    func testBundledManualIsIndexHTMLInTheManualFolder() throws {
        let manual = folder.appendingPathComponent("Manual", isDirectory: true)
        try FileManager.default.createDirectory(at: manual, withIntermediateDirectories: true)
        try "<title>M</title>".write(to: manual.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)

        let location = try XCTUnwrap(ManualLocation.bundled(in: folder))
        XCTAssertEqual(location.folder.standardizedFileURL, manual.standardizedFileURL)
        XCTAssertEqual(location.index.standardizedFileURL,
                       manual.appendingPathComponent("index.html").standardizedFileURL)
    }

    func testNoBundledManualWithoutIndexHTML() throws {
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Manual"),
                                                withIntermediateDirectories: true)
        XCTAssertNil(ManualLocation.bundled(in: folder))
        XCTAssertNil(ManualLocation.bundled(in: nil))
    }

    // MARK: Links

    func testWebLinksOpenInTheBrowser() {
        XCTAssertEqual(ManualLinkPolicy.decision(for: URL(string: "https://example.com/a")), .openInBrowser)
        XCTAssertEqual(ManualLinkPolicy.decision(for: URL(string: "http://example.com")), .openInBrowser)
        XCTAssertEqual(ManualLinkPolicy.decision(for: URL(string: "HTTPS://example.com")), .openInBrowser)
    }

    func testManualPagesLoadInTheWindow() {
        XCTAssertEqual(ManualLinkPolicy.decision(for: URL(fileURLWithPath: "/x/Manual/index.html#saving")), .allow)
        XCTAssertEqual(ManualLinkPolicy.decision(for: URL(string: "about:blank")), .allow)
    }

    func testOtherSchemesAreIgnored() {
        XCTAssertEqual(ManualLinkPolicy.decision(for: URL(string: "javascript:alert(1)")), .cancel)
        XCTAssertEqual(ManualLinkPolicy.decision(for: nil), .cancel)
    }

    // MARK: Window

    func testShowLoadsTheManualAndReusesTheWindow() async throws {
        try "<html><head><title>Fixture Manual</title></head><body><p>Hello</p></body></html>"
            .write(to: folder.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        let manual = ManualWindowController(location: ManualLocation(folder: folder))
        var finished = 0
        manual.onFinishLoading = { finished += 1 }

        manual.show()
        let window = try XCTUnwrap(manual.window)
        defer { window.close() }
        XCTAssertEqual(window.title, "PageCapture Manual")
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size, NSSize(width: 900, height: 800))
        XCTAssertTrue(window.styleMask.contains(.resizable))

        let deadline = Date().addingTimeInterval(10)
        while finished == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(finished, 1, "the manual did not finish loading")
        let webView = try XCTUnwrap(manual.webView)
        XCTAssertEqual(webView.url?.standardizedFileURL,
                       folder.appendingPathComponent("index.html").standardizedFileURL)
        XCTAssertEqual(webView.title, "Fixture Manual")
        XCTAssertFalse(webView.configuration.websiteDataStore.isPersistent)
        XCTAssertFalse(webView.configuration.defaultWebpagePreferences.allowsContentJavaScript)

        manual.show()
        XCTAssertTrue(manual.window === window, "a second show() opened another window")
    }
}

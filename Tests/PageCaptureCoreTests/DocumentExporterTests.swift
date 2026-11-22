import CoreServices
import XCTest
@testable import PageCaptureCore

/// Runs the real MarkItDown runtime from `build/tools/markitdown` on `Fixtures/documents`.
final class DocumentExporterTests: XCTestCase {
    private var folder: URL!
    private var documents: URL!
    private var converter: DocumentConverter!

    override func setUpWithError() throws {
        guard FileManager.default.isExecutableFile(atPath: DocumentConverterTests.python.path) else {
            throw XCTSkip("Run scripts/fetch-tools.sh markitdown first: build/tools/markitdown is missing")
        }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("DocumentExporterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        documents = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/documents", withExtension: nil))
        converter = DocumentConverter(pythonURL: DocumentConverterTests.python)
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    private func export(_ name: String, _ kind: DocumentKind, formats: Set<ExportFormat>) async throws -> ExportResult {
        try await DocumentExporter.export(documents.appendingPathComponent(name), kind: kind, formats: formats,
                                          to: folder.appendingPathComponent("My Report"), converter: converter)
    }

    private var written: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("My Report").path).sorted()) ?? []
    }

    func testWritesTheOriginalUnchangedAndItsMarkdown() async throws {
        let result = try await export("document.docx", .docx, formats: [.original, .markdown])
        let out = folder.appendingPathComponent("My Report")
        XCTAssertEqual(written, ["My Report.docx", "My Report.md"])
        XCTAssertEqual(result.original, out.appendingPathComponent("My Report.docx"))
        XCTAssertEqual(result.markdown, out.appendingPathComponent("My Report.md"))
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("My Report.docx")),
                       try Data(contentsOf: documents.appendingPathComponent("document.docx")))
        XCTAssertTrue(try String(contentsOf: out.appendingPathComponent("My Report.md"), encoding: .utf8)
            .contains("Quarterly Garden Review"))
        XCTAssertNil(result.documentMarkdownFailure)
        XCTAssertEqual(result.summary, "Saved to \(out.path)")
    }

    func testWritesOnlyTheChosenFormat() async throws {
        _ = try await export("text.pdf", .pdf, formats: [.original])
        XCTAssertEqual(written, ["My Report.pdf"])
        try FileManager.default.removeItem(at: folder.appendingPathComponent("My Report"))
        _ = try await export("sheet.xlsx", .xlsx, formats: [.markdown])
        XCTAssertEqual(written, ["My Report.md"])
    }

    /// The saved original is quarantined as a web download by PageCapture. (The source and page URLs
    /// go to LaunchServices' quarantine events, which do not give them back here, so they are not checked.)
    func testTheOriginalIsQuarantined() async throws {
        let source = URL(string: "https://documents.test/text.pdf")!
        let page = URL(string: "https://site.test/page.html")!
        let result = try await DocumentExporter.export(documents.appendingPathComponent("text.pdf"), kind: .pdf,
                                                       formats: [.original], to: folder.appendingPathComponent("My Report"),
                                                       downloadedFrom: source, page: page, converter: converter)
        let original = try XCTUnwrap(result.original)
        let size = getxattr(original.path, "com.apple.quarantine", nil, 0, 0, 0)
        XCTAssertGreaterThan(size, 0, "com.apple.quarantine is set")
        var value = [UInt8](repeating: 0, count: max(size, 0))
        XCTAssertEqual(getxattr(original.path, "com.apple.quarantine", &value, value.count, 0, 0), size)
        XCTAssertTrue(String(decoding: value, as: UTF8.self).hasPrefix("0081;"), String(decoding: value, as: UTF8.self))
        let properties = try XCTUnwrap(try original.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties)
        XCTAssertEqual(properties[kLSQuarantineAgentNameKey as String] as? String, "PageCapture")
        XCTAssertEqual(properties[kLSQuarantineTypeKey as String] as? String, kLSQuarantineTypeWebDownload as String)
    }

    func testNoTextFoundKeepsTheOriginal() async throws {
        converter.pdfFallback = { _ in throw DocumentConversionError.noTextFound }
        let blank = folder.appendingPathComponent("blank.pdf")
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        let context = try XCTUnwrap(CGContext(blank as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()

        let result = try await DocumentExporter.export(blank, kind: .pdf, formats: [.markdown],
                                                       to: folder.appendingPathComponent("My Report"), converter: converter)
        XCTAssertEqual(written, ["My Report.pdf"], "the original is kept although only Markdown was chosen")
        XCTAssertNil(result.markdown)
        XCTAssertEqual(result.documentMarkdownFailure, .noTextFound)
        XCTAssertTrue(result.summary.hasSuffix("(no text found in the document; the original was kept)"), result.summary)
    }

    func testConversionFailureKeepsTheOriginalAndGivesAReasonWithoutPaths() async throws {
        let result = try await export("corrupt.docx", .docx, formats: [.markdown])
        XCTAssertEqual(written, ["My Report.docx"])
        guard case .failed(let reason) = result.documentMarkdownFailure else {
            return XCTFail("\(String(describing: result.documentMarkdownFailure))")
        }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertFalse(reason.contains("\n"), reason)
        XCTAssertFalse(reason.contains("/"), reason)
        XCTAssertTrue(result.summary.contains("the Markdown could not be made (\(reason)); the original was kept"),
                      result.summary)
    }

    func testWholePageFallbackSaysThePageWasCaptured() {
        var result = ExportResult(folder: URL(fileURLWithPath: "/tmp/Name"), failedImages: [])
        result.documentFallback = .httpStatus(403)
        result.documentFallbackIsWholePage = true
        XCTAssertEqual(result.summary,
                       "Saved to /tmp/Name (the document could not be downloaded (HTTP 403), so the page was captured instead)")
    }

    func testFallbackReasonIsInTheSummary() {
        var result = ExportResult(folder: URL(fileURLWithPath: "/tmp/Name"), failedImages: [])
        result.documentFallback = .httpStatus(403)
        XCTAssertEqual(result.summary,
                       "Saved to /tmp/Name (the document could not be downloaded (HTTP 403), so the frame was captured as a page)")
    }
}

import CoreGraphics
import os
import XCTest
@testable import PageCaptureCore

/// Runs the real MarkItDown runtime from `build/tools/markitdown` (made by
/// `scripts/fetch-tools.sh markitdown`) on the documents in `Fixtures/documents`.
final class DocumentConverterTests: XCTestCase {
    private static let runtime = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("build/tools/markitdown", isDirectory: true)
    private static let python = runtime.appendingPathComponent("bin/python3")

    private var folder: URL!
    private var documents: URL!
    private var converter: DocumentConverter!

    override func setUpWithError() throws {
        guard FileManager.default.isExecutableFile(atPath: Self.python.path) else {
            throw XCTSkip("Run scripts/fetch-tools.sh markitdown first: build/tools/markitdown is missing")
        }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("DocumentConverterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        documents = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/documents", withExtension: nil))
        converter = DocumentConverter(pythonURL: Self.python)
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    // MARK: - Converting

    func testConvertsEachFixtureToMarkdown() async throws {
        let expected = [
            "text.pdf": ["Migratory Birds of the Lagoon", "The heron arrives in early spring."],
            "document.docx": ["# Quarterly Garden Review", "| Courgette | 37 kg |"],
            "slides.pptx": ["# Volcano Survey", "Basalt samples collected at dawn"],
            "sheet.xlsx": ["## Inventory", "| Lanterns | 12 |"],
            "page.html": ["# Harbour Report", "| Northwind | 4200 |"],
        ]
        for (file, texts) in expected.sorted(by: { $0.key < $1.key }) {
            let markdown = try await converter.markdown(forFile: documents.appendingPathComponent(file))
            for text in texts {
                XCTAssertTrue(markdown.contains(text), "\(file): \"\(text)\" is missing from:\n\(markdown)")
            }
        }
    }

    func testConvertsACopyNamedInputWithTheLowercasedExtension() async throws {
        let original = folder.appendingPathComponent("My \"odd\" page.HTML")
        try FileManager.default.copyItem(at: documents.appendingPathComponent("page.html"), to: original)
        let names = OSAllocatedUnfairLock<[String]>(initialState: [])
        converter.onLaunch = { _, directory in
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            names.withLock { $0 = contents }
        }

        let markdown = try await converter.markdown(forFile: original)

        XCTAssertTrue(markdown.contains("# Harbour Report"), markdown)
        XCTAssertEqual(names.withLock { $0 }, ["input.html"])
    }

    func testCorruptDocumentFailsWithMarkItDownsMessage() async throws {
        do {
            let markdown = try await converter.markdown(forFile: documents.appendingPathComponent("corrupt.docx"))
            XCTFail("Converted a corrupt DOCX to: \(markdown)")
        } catch let DocumentConversionError.failed(status, message) {
            XCTAssertNotEqual(status, 0)
            XCTAssertTrue(message.contains("FileConversionException"), message)
            XCTAssertLessThanOrEqual(message.utf8.count, 2048)
        }
    }

    func testMissingRuntimeIsReported() async throws {
        let missing = folder.appendingPathComponent("markitdown/bin/python3")
        do {
            _ = try await DocumentConverter(pythonURL: missing).markdown(forFile: documents.appendingPathComponent("page.html"))
            XCTFail("Converted without a runtime")
        } catch DocumentConversionError.runtimeMissing(let url) {
            XCTAssertEqual(url, missing)
        }
    }

    func testOutputLargerThanTheCapIsRejected() async throws {
        converter.maxOutputBytes = 16
        do {
            let markdown = try await converter.markdown(forFile: documents.appendingPathComponent("page.html"))
            XCTFail("Accepted \(markdown.utf8.count) bytes")
        } catch DocumentConversionError.outputTooLarge {}
    }

    // MARK: - Timeout

    func testTimeoutStopsTheWholeProcessGroupAndRemovesTheWorkDirectory() async throws {
        converter.timeout = .seconds(3)
        let launch = OSAllocatedUnfairLock<(pid: pid_t, directory: URL)?>(initialState: nil)
        converter.onLaunch = { pid, directory in launch.withLock { $0 = (pid, directory) } }
        // Python starts a child of its own, which must be stopped too.
        let script = """
            import subprocess, time
            subprocess.Popen(["/bin/sleep", "60"])
            time.sleep(60)
            """

        let start = ContinuousClock.now
        do {
            let output = try await converter.runScript(script)
            XCTFail("Not stopped: \(output)")
        } catch DocumentConversionError.timedOut {}

        // Stopped after the timeout (plus at most the SIGKILL grace period), not when Python was done.
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(10))
        let (pid, directory) = try XCTUnwrap(launch.withLock { $0 })
        XCTAssertEqual(killpg(pid, 0), -1, "Something in process group \(pid) is still running")
        XCTAssertEqual(errno, ESRCH)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testConversionTimesOut() async throws {
        converter.timeout = .milliseconds(1)
        do {
            let markdown = try await converter.markdown(forFile: documents.appendingPathComponent("page.html"))
            XCTFail("Not stopped: \(markdown)")
        } catch DocumentConversionError.timedOut {}
    }

    // MARK: - Sandbox

    func testSandboxDeniesNetworkAndWritesOutsideTheWorkDirectory() async throws {
        // The work directory's path has spaces, quotes and brackets in it.
        let root = folder.appendingPathComponent("odd \"quoted\" (root) \\ dir", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        converter.temporaryRoot = root
        let outside = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: outside) }
        let script = """
            import errno, os, sys, urllib.request
            def attempt(action):
                try:
                    action()
                    return "allowed"
                except OSError as error:
                    error = getattr(error, "reason", error)
                    return errno.errorcode.get(getattr(error, "errno", None), repr(error))
            def write(path):
                with open(path, "w") as file:
                    file.write("x")
            print("network", attempt(lambda: urllib.request.urlopen("http://1.1.1.1", timeout=3)))
            print("outside", attempt(lambda: write(sys.argv[1])))
            print("inside", attempt(lambda: write(os.path.join(os.getcwd(), "inside.txt"))))
            print("directory", os.getcwd())
            """

        let output = try await converter.runScript(script, arguments: [outside.path])

        let lines = output.split(separator: "\n").map(String.init)
        XCTAssertEqual(Array(lines.prefix(3)), ["network EPERM", "outside EPERM", "inside allowed"], output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
        let realRoot = try XCTUnwrap(realpath(root.path, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        })
        XCTAssertTrue(lines.last?.hasPrefix("directory \(realRoot)/PageCapture-DocumentConverter-") == true, output)
    }

    func testConvertingWritesNothingIntoTheRuntime() async throws {
        let before = try Self.listing(of: Self.runtime)
        _ = try await converter.markdown(forFile: documents.appendingPathComponent("text.pdf"))
        _ = try await converter.markdown(forFile: documents.appendingPathComponent("document.docx"))
        let after = try Self.listing(of: Self.runtime)
        XCTAssertGreaterThan(before.count, 100)
        XCTAssertEqual(before, after)
    }

    // MARK: - PDF fallback

    func testPDFWithoutTextUsesTheFallback() async throws {
        let blank = folder.appendingPathComponent("Scan.PDF")
        try Self.writeRectangleOnlyPDF(to: blank)
        let calls = OSAllocatedUnfairLock<[(name: String, existed: Bool)]>(initialState: [])
        converter.pdfFallback = { url in
            calls.withLock { $0.append((url.lastPathComponent, FileManager.default.fileExists(atPath: url.path))) }
            return "Recognised text"
        }

        let markdown = try await converter.markdown(forFile: blank)

        XCTAssertEqual(markdown, "Recognised text")
        let made = calls.withLock { $0 }
        XCTAssertEqual(made.map(\.name), ["input.pdf"])
        XCTAssertEqual(made.map(\.existed), [true])
    }

    func testPDFWithTextDoesNotUseTheFallback() async throws {
        let called = OSAllocatedUnfairLock(initialState: false)
        converter.pdfFallback = { _ in
            called.withLock { $0 = true }
            return "Recognised text"
        }

        let markdown = try await converter.markdown(forFile: documents.appendingPathComponent("text.pdf"))

        XCTAssertTrue(markdown.contains("Migratory Birds of the Lagoon"), markdown)
        XCTAssertFalse(called.withLock { $0 })
    }

    // MARK: - Helpers

    /// Every file and folder under `directory` with its size and modification date.
    private static func listing(of directory: URL) throws -> [String: String] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys))
        var listing = [String: String]()
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            listing[url.path] = "\(values.fileSize ?? -1) \(values.contentModificationDate?.timeIntervalSince1970 ?? -1)"
        }
        return listing
    }

    /// A one-page PDF with a filled rectangle and no text, like a scan.
    private static func writeRectangleOnlyPDF(to url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 0.2, alpha: 1))
        context.fill(CGRect(x: 40, y: 40, width: 120, height: 80))
        context.endPDFPage()
        context.closePDF()
    }
}

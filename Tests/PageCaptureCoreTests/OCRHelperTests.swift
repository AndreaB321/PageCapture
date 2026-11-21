import os
import XCTest
@testable import PageCaptureCore

/// Runs the `pagecapture-ocr` helper built with the tests (`swift build --build-tests` builds every
/// product, the helper included) the way `DocumentConverter` runs it on a scanned PDF: under
/// `sandbox-exec` with `ocrSandboxProfile`. Its debug build has `--probe-…` arguments that show
/// what the sandbox lets it do. The scan tests also need the MarkItDown runtime in `build/tools`.
final class OCRHelperTests: XCTestCase {
    /// The helper next to the test bundle, or in `.build/debug`.
    private static let helper: URL? = {
        let candidates = [
            Bundle.module.bundleURL.deletingLastPathComponent().appendingPathComponent("pagecapture-ocr"),
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent(".build/debug/pagecapture-ocr"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }()

    private var folder: URL!
    private var helper: URL!
    private var converter: DocumentConverter!

    override func setUpWithError() throws {
        guard let helper = Self.helper else {
            throw XCTSkip("pagecapture-ocr is not built: run swift build --build-tests")
        }
        self.helper = helper
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("OCRHelperTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        converter = DocumentConverter(pythonURL: DocumentConverterTests.python, ocrHelperURL: helper)
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    private func requireRuntime() throws {
        guard FileManager.default.isExecutableFile(atPath: DocumentConverterTests.python.path) else {
            throw XCTSkip("Run scripts/fetch-tools.sh markitdown first: build/tools/markitdown is missing")
        }
    }

    // MARK: - Scanned PDFs

    /// MarkItDown finds no text, so the helper runs, in a sandboxed process of its own: not OCR
    /// in the app's (here the tests') process.
    func testScannedPDFIsReadByTheSandboxedHelper() async throws {
        try requireRuntime()
        let scan = folder.appendingPathComponent("scan.pdf")
        try DocumentConverterTests.writeScannedPDF(line: "PageCapture reads scanned pages", to: scan)
        let launches = OSAllocatedUnfairLock<[pid_t]>(initialState: [])
        converter.onLaunch = { pid, _ in launches.withLock { $0.append(pid) } }

        let markdown = try await converter.markdown(forFile: scan)

        XCTAssertTrue(markdown.lowercased().contains("pagecapture reads scanned pages"), markdown)
        let pids = launches.withLock { $0 }
        XCTAssertEqual(pids.count, 2, "Expected two sandboxed runs, Python then the OCR helper: \(pids)")
        XCTAssertEqual(Set(pids).count, pids.count)
    }

    func testBlankScanHasNoText() async throws {
        try requireRuntime()
        let scan = folder.appendingPathComponent("blank.pdf")
        try DocumentConverterTests.writeScannedPDF(line: "", to: scan)

        do {
            let markdown = try await converter.markdown(forFile: scan)
            XCTFail("Read text from a blank page: \(markdown)")
        } catch DocumentConversionError.noTextFound {}
    }

    func testMissingHelperIsReported() async throws {
        try requireRuntime()
        let scan = folder.appendingPathComponent("scan.pdf")
        try DocumentConverterTests.writeScannedPDF(line: "PageCapture reads scanned pages", to: scan)
        let missing = folder.appendingPathComponent("Helpers/pagecapture-ocr")
        converter.ocrHelperURL = missing

        do {
            let markdown = try await converter.markdown(forFile: scan)
            XCTFail("Read a scan without the helper: \(markdown)")
        } catch DocumentConversionError.runtimeMissing(let url) {
            XCTAssertEqual(url, missing)
        }
    }

    /// Run directly, outside any sandbox: a file that is not a PDF is reported as unreadable, and
    /// the message does not name its path.
    func testHelperReportsAFileThatIsNotAPDFAsUnreadable() throws {
        let junk = folder.appendingPathComponent("junk.pdf")
        var generator = SystemRandomNumberGenerator()
        try Data((0..<4096).map { _ in UInt8.random(in: .min ... .max, using: &generator) }).write(to: junk)

        let (status, _, errors) = try Self.runUnsandboxed(helper, [junk.path])

        XCTAssertEqual(status, 3, errors)
        XCTAssertFalse(errors.contains(junk.lastPathComponent), errors)
    }

    // MARK: - Sandbox

    func testSandboxDeniesReadingOutsideItsTrees() async throws {
        let secret = folder.appendingPathComponent("secret.txt")
        try "secret".write(to: secret, atomically: true, encoding: .utf8)
        let realSecret = try XCTUnwrap(realpath(secret.path, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        })

        let denied = try await converter.runOCRHelper(arguments: ["--probe-read", realSecret])
        let allowed = try await converter.runOCRHelper(arguments: ["--probe-read", "/System/Library/CoreServices/SystemVersion.plist"])

        XCTAssertEqual(denied.status, 0)
        XCTAssertEqual(denied.output, "EPERM\n")
        XCTAssertEqual(allowed.output, "allowed\n", "The helper cannot read the system it needs")
    }

    func testSandboxDeniesTheNetwork() async throws {
        let listener = try Self.listenOnLoopback()
        defer { close(listener.descriptor) }
        // Outside the sandbox, the helper reaches the listener.
        let (_, unsandboxed, _) = try Self.runUnsandboxed(helper, ["--probe-net", String(listener.port)])
        XCTAssertEqual(unsandboxed, "allowed\n")

        let sandboxed = try await converter.runOCRHelper(arguments: ["--probe-net", String(listener.port)])

        XCTAssertEqual(sandboxed.status, 0)
        XCTAssertEqual(sandboxed.output, "EPERM\n")
    }

    // MARK: - Stopping

    func testTimeoutStopsTheHelper() async throws {
        converter.ocrTimeout = .seconds(1)
        let launch = OSAllocatedUnfairLock<(pid: pid_t, directory: URL)?>(initialState: nil)
        converter.onLaunch = { pid, directory in launch.withLock { $0 = (pid, directory) } }
        let start = ContinuousClock.now

        do {
            let result = try await converter.runOCRHelper(arguments: ["--probe-sleep", "30"])
            XCTFail("Not stopped: \(result)")
        } catch DocumentConversionError.timedOut {}

        // The timeout plus at most the SIGKILL grace period, not the 30 s the helper sleeps.
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(6))
        let (pid, directory) = try XCTUnwrap(launch.withLock { $0 })
        try await DocumentConverterTests.assertGroupGone(pid)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testStopAllRunningStopsTheHelper() async throws {
        let launch = OSAllocatedUnfairLock<(pid: pid_t, directory: URL)?>(initialState: nil)
        converter.onLaunch = { pid, directory in launch.withLock { $0 = (pid, directory) } }
        let converter = converter!
        let task = Task { try await converter.runOCRHelper(arguments: ["--probe-sleep", "30"]) }
        let (pid, directory) = try await DocumentConverterTests.waitForLaunch(launch)
        let stopped = ContinuousClock.now

        Tools.stopAllRunning()
        let result = try await task.value

        XCTAssertEqual(result.status, SIGTERM, result.output)
        XCTAssertLessThan(ContinuousClock.now - stopped, .seconds(5))
        try await DocumentConverterTests.assertGroupGone(pid)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    // MARK: - Helpers

    /// Runs `executable` with `arguments`, no sandbox, and returns its exit status, stdout and stderr.
    private static func runUnsandboxed(_ executable: URL, _ arguments: [String]) throws -> (Int32, String, String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errors = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self), String(decoding: errors, as: UTF8.self))
    }

    /// A TCP socket listening on 127.0.0.1 at a port the system picked.
    private static func listenOnLoopback() throws -> (descriptor: Int32, port: UInt16) {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, length) == 0 && Darwin.listen(descriptor, 4) == 0 && getsockname(descriptor, $0, &length) == 0
            }
        }
        guard bound else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            close(descriptor)
            throw error
        }
        return (descriptor, UInt16(bigEndian: address.sin_port))
    }
}

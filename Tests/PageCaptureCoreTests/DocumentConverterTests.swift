import CoreGraphics
import CoreText
import os
import XCTest
@testable import PageCaptureCore

/// Runs the real MarkItDown runtime from `build/tools/markitdown` (made by
/// `scripts/fetch-tools.sh markitdown`) on the documents in `Fixtures/documents`.
final class DocumentConverterTests: XCTestCase {
    private static let runtime = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("build/tools/markitdown", isDirectory: true)
    static let python = runtime.appendingPathComponent("bin/python3")

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
        // Python starts a child of its own, which must be stopped too (if the sandbox let it).
        converter.profile = Self.forkingProfile
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

    /// Python has exited when the time is up, but its output is still being read (a process that
    /// left its group holds it open): that run has not timed out.
    func testRunThatExitedBeforeTheTimeoutIsNotATimeout() async throws {
        converter.timeout = .milliseconds(1500)
        converter.profile = Self.forkingProfile
        let output = try await converter.runScript(Self.leaveAProcessHoldingTheOutput(exitAfter: 0.5))
        let escaped = try XCTUnwrap(pid_t(output.trimmingCharacters(in: .whitespacesAndNewlines)), output)
        Darwin.kill(escaped, SIGKILL)
    }

    // MARK: - Stopping

    func testCancellingStopsTheRunAndRemovesTheWorkDirectory() async throws {
        let launch = OSAllocatedUnfairLock<(pid: pid_t, directory: URL)?>(initialState: nil)
        converter.onLaunch = { pid, directory in launch.withLock { $0 = (pid, directory) } }
        let converter = converter!
        let task = Task { try await converter.runScript("import time\ntime.sleep(30)") }
        let (pid, directory) = try await Self.waitForLaunch(launch)

        let cancelled = ContinuousClock.now
        task.cancel()
        do {
            let output = try await task.value
            XCTFail("Not cancelled: \(output)")
        } catch is CancellationError {}

        XCTAssertLessThan(ContinuousClock.now - cancelled, .seconds(5))
        try await Self.assertGroupGone(pid)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testStopAllRunningStopsAConversion() async throws {
        let launch = OSAllocatedUnfairLock<(pid: pid_t, directory: URL)?>(initialState: nil)
        converter.onLaunch = { pid, directory in launch.withLock { $0 = (pid, directory) } }
        let converter = converter!
        let task = Task { try await converter.runScript("import time\ntime.sleep(30)") }
        let (pid, directory) = try await Self.waitForLaunch(launch)

        Tools.stopAllRunning()
        do {
            let output = try await task.value
            XCTFail("Not stopped: \(output)")
        } catch let DocumentConversionError.failed(status, _) {
            XCTAssertEqual(status, SIGTERM)
        }

        try await Self.assertGroupGone(pid)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    /// With a sandbox that let Python start processes: one it left running in its group is killed
    /// as soon as Python exits.
    func testNothingPythonStartedOutlivesIt() async throws {
        converter.profile = Self.forkingProfile
        let script = """
            import subprocess
            child = subprocess.Popen(["/bin/sleep", "30"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            print(child.pid)
            """

        let output = try await converter.runScript(script)

        let child = try XCTUnwrap(pid_t(output.trimmingCharacters(in: .whitespacesAndNewlines)), output)
        defer { Darwin.kill(child, SIGKILL) }
        try await Self.assertGone(child)
    }

    /// With a sandbox that let Python start processes: one that left its group and keeps the output
    /// open cannot be killed, but the run still returns soon after Python exits.
    func testRunReturnsWhenAProcessThatLeftTheGroupKeepsTheOutputOpen() async throws {
        converter.profile = Self.forkingProfile
        let start = ContinuousClock.now

        let output = try await converter.runScript(Self.leaveAProcessHoldingTheOutput(exitAfter: 0))

        XCTAssertLessThan(ContinuousClock.now - start, .seconds(10))
        let escaped = try XCTUnwrap(pid_t(output.trimmingCharacters(in: .whitespacesAndNewlines)), output)
        Darwin.kill(escaped, SIGKILL)
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

    func testSandboxDeniesStartingProcesses() async throws {
        let output = try await converter.runScript(Self.attempt + """
            import subprocess
            def fork():
                pid = os.fork()
                if pid == 0:
                    os._exit(0)
                os.waitpid(pid, 0)
            print("fork", attempt(fork))
            print("subprocess", attempt(lambda: subprocess.run(["/usr/bin/true"])))
            print("posix_spawn", attempt(lambda: os.waitpid(os.posix_spawn("/usr/bin/true", ["true"], {}), 0)))
            sys.stdout.flush()
            print("exec", attempt(lambda: os.execv("/usr/bin/true", ["true"])))
            """)

        XCTAssertEqual(output.split(separator: "\n"), ["fork EPERM", "subprocess EPERM", "posix_spawn EPERM", "exec EPERM"], output)
    }

    func testSandboxDeniesReadingOutsideTheRuntimeAndTheWorkDirectory() async throws {
        let secret = folder.appendingPathComponent("secret.txt")
        try "secret".write(to: secret, atomically: true, encoding: .utf8)
        let realSecret = try XCTUnwrap(realpath(secret.path, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        })

        let output = try await converter.runScript(Self.attempt + """
            print("file", attempt(lambda: open(sys.argv[1]).read()))
            print("through /System", attempt(lambda: open("/System/Volumes/Data" + sys.argv[1]).read()))
            print("home", attempt(lambda: os.listdir(sys.argv[2])))
            """, arguments: [realSecret, NSHomeDirectory()])

        XCTAssertEqual(output.split(separator: "\n"), ["file EPERM", "through /System EPERM", "home EPERM"], output)
    }

    func testSandboxDeniesSignallingOtherProcesses() async throws {
        let sleep = Process()
        sleep.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleep.arguments = ["30"]
        try sleep.run()
        defer { sleep.terminate() }

        let output = try await converter.runScript(Self.attempt + """
            print("kill", attempt(lambda: os.kill(int(sys.argv[1]), 15)))
            """, arguments: [String(sleep.processIdentifier)])

        XCTAssertEqual(output, "kill EPERM\n")
        XCTAssertTrue(sleep.isRunning)
    }

    func testSandboxDeniesSystemServices() async throws {
        let output = try await converter.runScript("""
            import ctypes
            system = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
            port = ctypes.c_uint(0)
            bootstrap = ctypes.c_uint.in_dll(system, "bootstrap_port")
            print("lookup", system.bootstrap_look_up(bootstrap, b"com.apple.cfprefsd.daemon", ctypes.byref(port)))
            """)

        XCTAssertTrue(output.hasPrefix("lookup "), output)
        XCTAssertNotEqual(output, "lookup 0\n", "Python reached the preferences daemon")
    }

    func testPythonIsIsolatedWithAMinimalEnvironment() async throws {
        let output = try await converter.runScript("""
            import os, sys
            print(sys.flags.isolated, sys.dont_write_bytecode)
            print(" ".join(sorted(os.environ)))
            """)

        XCTAssertEqual(output.split(separator: "\n"), [
            "1 True",
            "HOME LANG PATH PYTHONDONTWRITEBYTECODE PYTHONIOENCODING TMPDIR",
        ], output)
    }

    /// In the app, `Helpers/markitdown` is a link to `Resources/markitdown`.
    func testRunsThePythonOfARuntimeReachedThroughALink() async throws {
        let helpers = folder.appendingPathComponent("Odd \"Helpers\"", isDirectory: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        let link = helpers.appendingPathComponent("markitdown")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: Self.runtime)
        converter.pythonURL = link.appendingPathComponent("bin/python3")

        let markdown = try await converter.markdown(forFile: documents.appendingPathComponent("page.html"))

        XCTAssertTrue(markdown.contains("# Harbour Report"), markdown)
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

    /// The sandbox before it denied starting processes, for tests of what the run must survive if
    /// Python could.
    private static let forkingProfile = """
        (version 1)
        (allow default)
        (deny network*)
        (deny file-write*)
        (allow file-write* (subpath (param "WORK_DIR")) (literal "/dev/null"))
        """

    /// Python's `attempt(action)`: "allowed", or the name of the errno it failed with.
    private static let attempt = """
        import errno, os, sys
        def attempt(action):
            try:
                action()
                return "allowed"
            except OSError as error:
                return errno.errorcode.get(error.errno, repr(error))

        """

    /// Forks a child that leaves Python's process group and sleeps for 30 s with the output open,
    /// prints its pid, and exits after `seconds`.
    private static func leaveAProcessHoldingTheOutput(exitAfter seconds: Double) -> String {
        """
        import os, sys, time
        child = os.fork()
        if child == 0:
            os.setsid()
            time.sleep(30)
            os._exit(0)
        print(child)
        sys.stdout.flush()
        time.sleep(\(seconds))
        """
    }

    static func waitForLaunch(_ launch: OSAllocatedUnfairLock<(pid: pid_t, directory: URL)?>) async throws -> (pid_t, URL) {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if let launched = launch.withLock({ $0 }) {
                // Python is past its start-up and asleep.
                try await Task.sleep(for: .milliseconds(500))
                return launched
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        return try XCTUnwrap(launch.withLock { $0 }, "Python did not start within 10 s")
    }

    /// Waits up to 3 s for `pid` to be gone.
    private static func assertGone(_ pid: pid_t, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline, Darwin.kill(pid, 0) == 0 { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNotEqual(Darwin.kill(pid, 0), 0, "Process \(pid) is still running", file: file, line: line)
    }

    /// Waits up to 3 s for everything in process group `group` to be gone.
    static func assertGroupGone(_ group: pid_t, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline, killpg(group, 0) == 0 { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNotEqual(killpg(group, 0), 0, "Something in process group \(group) is still running", file: file, line: line)
    }

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

    /// A one-page PDF whose only content is a picture of `line` in black on white: a scan.
    static func writeScannedPDF(line: String, to url: URL) throws {
        let size = CGSize(width: 612, height: 792), scale: CGFloat = 4
        let bitmap = try XCTUnwrap(CGContext(
            data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        bitmap.setFillColor(gray: 1, alpha: 1)
        bitmap.fill(CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height))
        bitmap.scaleBy(x: scale, y: scale)
        let font = CTFontCreateWithName("Helvetica" as CFString, 22, nil)
        let text = NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: CGColor(gray: 0, alpha: 1)])
        bitmap.textPosition = CGPoint(x: 50, y: 650)
        CTLineDraw(CTLineCreateWithAttributedString(text), bitmap)
        let image = try XCTUnwrap(bitmap.makeImage())
        var box = CGRect(origin: .zero, size: size)
        let pdf = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        pdf.beginPDFPage(nil)
        pdf.draw(image, in: box)
        pdf.endPDFPage()
        pdf.closePDF()
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

import Foundation
import os
import PageCaptureOCRKit

public enum DocumentConversionError: Error, Equatable {
    /// The bundled Python is not where it should be (e.g. running from `swift run` without a built app).
    case runtimeMissing(URL)
    /// The conversion took longer than the converter's timeout and was stopped.
    case timedOut
    /// MarkItDown failed. `message` is the end of what it wrote to stderr (about 2 KB), e.g. a
    /// traceback ending in `UnsupportedFormatException` or `FileConversionException`.
    case failed(status: Int32, message: String)
    /// The Markdown was longer than the converter's `maxOutputBytes`; the conversion was stopped.
    case outputTooLarge
}

/// Converts one local file (PDF, DOCX, PPTX, XLSX, HTML, …) to Markdown with the bundled MarkItDown.
///
/// The file is untrusted (downloaded from the web), so it never reaches MarkItDown in place: it is
/// copied into a private work directory under a fixed name, and Python runs in a sandbox that
/// allows little more than reading the runtime and the system libraries and writing in that
/// directory (`sandboxProfile`), with a minimal environment of its own. The work directory is
/// deleted afterwards, whatever happened.
public struct DocumentConverter: Sendable {
    /// `markitdown/bin/python3` of the bundled runtime.
    public var pythonURL: URL
    /// How long one conversion may take before it is stopped.
    public var timeout: Duration
    /// The longest Markdown accepted, in bytes.
    public var maxOutputBytes: Int
    /// Called with the copy of a `.pdf` whose conversion succeeded but produced no text (a scanned
    /// PDF); what it returns is the result instead. The copy is deleted once it returns.
    public var pdfFallback: (@Sendable (URL) async throws -> String)?

    /// Where the work directories are made. Tests use one with spaces and quotes in its path.
    var temporaryRoot = FileManager.default.temporaryDirectory
    /// Called once the sandboxed process is running, with its pid (also its process group) and
    /// its work directory. For tests.
    var onLaunch: (@Sendable (pid_t, URL) -> Void)?
    /// The sandbox profile Python runs under. Tests use a looser one to check what happens when
    /// Python can start processes, which `sandboxProfile` denies.
    var profile = DocumentConverter.sandboxProfile

    public init(
        pythonURL: URL = DocumentConverter.bundledPythonURL,
        timeout: Duration = .seconds(120),
        maxOutputBytes: Int = 50 << 20,
        pdfFallback: (@Sendable (URL) async throws -> String)? = DocumentConverter.recognizeScannedPDF
    ) {
        self.pythonURL = pythonURL
        self.timeout = timeout
        self.maxOutputBytes = maxOutputBytes
        self.pdfFallback = pdfFallback
    }

    /// The default `pdfFallback`: on-device Vision OCR of the PDF's pages (`PDFTextRecognizer`).
    public static let recognizeScannedPDF: @Sendable (URL) async throws -> String = { url in
        try await PDFTextRecognizer.markdown(fromPDF: url)
    }

    /// `markitdown/bin/python3` in `Contents/Helpers` of the app (a link to `Contents/Resources/markitdown`).
    public static var bundledPythonURL: URL {
        Tools.bundledHelpersDirectory.appendingPathComponent("markitdown/bin/python3")
    }

    /// The Markdown for the file at `url`.
    public func markdown(forFile url: URL) async throws -> String {
        try checkRuntime()
        return try await withWorkDirectory { directory in
            let fileExtension = Self.sanitisedExtension(url.pathExtension)
            let copy = directory.appendingPathComponent(fileExtension.isEmpty ? "input" : "input.\(fileExtension)")
            try FileManager.default.copyItem(at: url.resolvingSymlinksInPath(), to: copy)
            let markdown = try await runSandboxed(Self.convertScript, arguments: [copy.path], in: directory)
            if fileExtension == "pdf", let pdfFallback, markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return try await pdfFallback(copy)
            }
            return markdown
        }
    }

    /// Runs a Python snippet exactly the way `markdown(forFile:)` runs MarkItDown, in a work
    /// directory of its own, and returns its stdout. For tests of the sandbox and the timeout.
    func runScript(_ script: String, arguments: [String] = []) async throws -> String {
        try checkRuntime()
        return try await withWorkDirectory { try await runSandboxed(script, arguments: arguments, in: $0) }
    }

    // MARK: - Sandboxed run

    /// Converts `sys.argv[1]`, a local file, and writes the Markdown to stdout as UTF-8. Only
    /// `convert_local`: MarkItDown never gets a URL or a stream to fetch.
    static let convertScript = """
        import sys
        from markitdown import MarkItDown
        result = MarkItDown(enable_plugins=False).convert_local(sys.argv[1])
        sys.stdout.buffer.write((result.text_content or "").encode("utf-8"))
        """

    /// Denies everything but what converting the fixtures needs: running the runtime's Python
    /// (`PYTHON`, its real path, which `sandbox-exec` executes), reading the runtime (`RUNTIME`),
    /// the work directory (`WORK_DIR`), `/` itself and the system libraries, writing in the work
    /// directory and to /dev/null, and reading sysctls. So there is no network, no child process
    /// (`process-fork` is denied), no other executable, no signal to another process, no Mach
    /// service (no preferences, pasteboard, Launch Services or window server), and no file of the
    /// user's. `/System` does not reach user files through `/System/Volumes/Data`: the sandbox
    /// matches the path a file resolves to. The paths come in as parameters (`-D NAME=…`), never
    /// spliced into the profile's text, so no path can change the profile.
    static let sandboxProfile = """
        (version 1)
        (deny default)
        (allow process-exec (literal (param "PYTHON")))
        (allow file-read*
            (literal "/") (subpath "/System") (subpath "/usr/lib") (literal "/dev/null")
            (subpath (param "RUNTIME")) (subpath (param "WORK_DIR")))
        (allow file-write* (subpath (param "WORK_DIR")) (literal "/dev/null"))
        (allow sysctl-read)
        """

    /// How much of the end of stderr goes into `failed(status:message:)`.
    private static let stderrTail = 2048
    /// How long the output is still read once Python has exited and its process group is killed.
    /// Only a process that left the group can hold the pipes open that long.
    private static let drainTime: Duration = .seconds(1)

    private func checkRuntime() throws {
        guard FileManager.default.isExecutableFile(atPath: pythonURL.path) else {
            throw DocumentConversionError.runtimeMissing(pythonURL)
        }
    }

    /// Makes a fresh private directory, runs `body` with its real path (the sandbox matches real
    /// paths, and the temporary folder is behind the `/var` link), and deletes it afterwards.
    private func withWorkDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
        let fm = FileManager.default
        let directory = temporaryRoot.appendingPathComponent("PageCapture-DocumentConverter-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: directory) }
        return try await body(Self.realPath(directory, isDirectory: true))
    }

    /// Runs `python3 -I -B -c script arguments…` under `sandbox-exec` in `directory` and returns
    /// its stdout. Stops it (its whole process group) on timeout, when stdout passes
    /// `maxOutputBytes`, or when the calling task is cancelled. Once Python has exited, kills what
    /// is left in its group and reads the output for at most `drainTime` more, so it always returns.
    private func runSandboxed(_ script: String, arguments: [String], in directory: URL) async throws -> String {
        // The real path: the sandbox matches it, and the app's `Helpers/markitdown` is a link.
        let python = Self.realPath(pythonURL, isDirectory: false)
        let runtime = python.deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-D", "WORK_DIR=\(directory.path)", "-D", "RUNTIME=\(runtime.path)",
                             "-D", "PYTHON=\(python.path)", "-p", profile,
                             python.path, "-I", "-B", "-c", script] + arguments
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "HOME": directory.path,
            "TMPDIR": directory.path,
            "PYTHONDONTWRITEBYTECODE": "1",
            "PYTHONIOENCODING": "utf-8",
            "LANG": "en_US.UTF-8",
        ]
        process.currentDirectoryURL = directory
        let stdout = Pipe(), stderr = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        let exit = ExitStatus()
        let running = RunningProcess()
        process.terminationHandler = {
            running.reaped()
            exit.exited($0.terminationStatus)
        }
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let tooLarge = OSAllocatedUnfairLock(initialState: false)
        let readingStopped = OSAllocatedUnfairLock(initialState: false)
        let (timeout, maxOutputBytes, onLaunch) = (timeout, maxOutputBytes, onLaunch)

        let (status, output, errors) = try await withTaskCancellationHandler {
            try process.run()
            running.launched(group: process.processIdentifier)
            defer { running.finished() }
            if Task.isCancelled { running.stop() }
            onLaunch?(process.processIdentifier, directory)
            let timer = Task {
                try await Task.sleep(for: timeout)
                // A run that has exited has not timed out, even if its output is still being read.
                guard !exit.hasExited else { return }
                timedOut.withLock { $0 = true }
                running.stop()
            }
            defer { timer.cancel() }
            async let out = Self.read(stdout.fileHandleForReading, limit: maxOutputBytes, until: readingStopped) {
                tooLarge.withLock { $0 = true }
                running.stop()
            }
            async let err = Self.read(stderr.fileHandleForReading, limit: Self.stderrTail, keepingEnd: true,
                                      until: readingStopped)
            let status = await exit.wait()
            // Nothing Python started may outlive it, and only what left its group can still hold
            // the pipes open: read them for `drainTime` at most.
            running.killGroup()
            let drain = Task {
                try await Task.sleep(for: Self.drainTime)
                readingStopped.withLock { $0 = true }
            }
            defer { drain.cancel() }
            return (status, await out, await err)
        } onCancel: {
            running.stop()
        }

        if timedOut.withLock({ $0 }) { throw DocumentConversionError.timedOut }
        if tooLarge.withLock({ $0 }) { throw DocumentConversionError.outputTooLarge }
        try Task.checkCancellation()
        guard status == 0 else {
            let message = String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw DocumentConversionError.failed(status: status, message: message.isEmpty ? "Exited with status \(status)" : message)
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// Reads `handle` to its end, or until `stopped` is set, on a background thread, keeping at
    /// most `limit` bytes: the first ones, calling `overflow` once when there are more, or the last
    /// ones if `keepingEnd`. Reading goes on either way, so the writer never blocks on a full pipe.
    private static func read(_ handle: FileHandle, limit: Int, keepingEnd: Bool = false,
                             until stopped: OSAllocatedUnfairLock<Bool>,
                             overflow: (@Sendable () -> Void)? = nil) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let size = 64 << 10
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
                defer { buffer.deallocate() }
                var data = Data()
                var overflowed = false
                var readable = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
                while !stopped.withLock({ $0 }) {
                    // Wakes up every 100 ms to see whether to stop.
                    let polled = poll(&readable, 1, 100)
                    if polled < 0, errno == EINTR { continue }
                    guard polled > 0 else {
                        if polled == 0 { continue } else { break }
                    }
                    let count = Darwin.read(handle.fileDescriptor, buffer, size)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { break }
                    if overflowed { continue }
                    data.append(buffer, count: count)
                    guard data.count > limit else { continue }
                    if keepingEnd {
                        data = data.suffix(limit)
                    } else {
                        overflowed = true
                        data = Data()
                        overflow?()
                    }
                }
                continuation.resume(returning: data)
            }
        }
    }

    // MARK: - Paths

    /// The extension in lower case, with only ASCII letters and digits, at most 16 of them.
    static func sanitisedExtension(_ pathExtension: String) -> String {
        String(pathExtension.lowercased().unicodeScalars
            .filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
            .prefix(16).map(Character.init))
    }

    private static func realPath(_ url: URL, isDirectory: Bool) -> URL {
        guard let resolved = realpath(url.path, nil) else { return url }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: isDirectory)
    }
}

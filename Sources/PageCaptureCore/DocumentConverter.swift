import Foundation
import os

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
/// denies all network access and every file write outside that directory, with a minimal
/// environment of its own. The work directory is deleted afterwards, whatever happened.
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

    public init(
        pythonURL: URL = DocumentConverter.bundledPythonURL,
        timeout: Duration = .seconds(120),
        maxOutputBytes: Int = 50 << 20,
        pdfFallback: (@Sendable (URL) async throws -> String)? = nil
    ) {
        self.pythonURL = pythonURL
        self.timeout = timeout
        self.maxOutputBytes = maxOutputBytes
        self.pdfFallback = pdfFallback
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

    /// No network, no file writes except in the work directory (and /dev/null); reads stay allowed.
    /// The work directory comes in as a parameter (`-D WORK_DIR=…`), never spliced into the
    /// profile's text, so no path can change the profile.
    static let sandboxProfile = """
        (version 1)
        (allow default)
        (deny network*)
        (deny file-write*)
        (allow file-write* (subpath (param "WORK_DIR")) (literal "/dev/null"))
        """

    /// How much of the end of stderr goes into `failed(status:message:)`.
    private static let stderrTail = 2048

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
        return try await body(Self.realPath(directory))
    }

    /// Runs `python3 -I -B -c script arguments…` under `sandbox-exec` in `directory` and returns
    /// its stdout. Stops it (its whole process group) on timeout, when stdout passes
    /// `maxOutputBytes`, or when the calling task is cancelled, and returns only once it has exited
    /// and its output has been read to the end.
    private func runSandboxed(_ script: String, arguments: [String], in directory: URL) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-D", "WORK_DIR=\(directory.path)", "-p", Self.sandboxProfile,
                             pythonURL.path, "-I", "-B", "-c", script] + arguments
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
        process.terminationHandler = { exit.exited($0.terminationStatus) }
        let running = RunningProcess()
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let tooLarge = OSAllocatedUnfairLock(initialState: false)
        let (timeout, maxOutputBytes, onLaunch) = (timeout, maxOutputBytes, onLaunch)

        let (status, output, errors) = try await withTaskCancellationHandler {
            try process.run()
            running.launched(group: process.processIdentifier)
            // Until the output is read to the end, which also waits for whatever Python started.
            defer { running.finished() }
            if Task.isCancelled { running.stop() }
            onLaunch?(process.processIdentifier, directory)
            let timer = Task {
                try await Task.sleep(for: timeout)
                timedOut.withLock { $0 = true }
                running.stop()
            }
            defer { timer.cancel() }
            async let out = Self.read(stdout.fileHandleForReading, limit: maxOutputBytes) {
                tooLarge.withLock { $0 = true }
                running.stop()
            }
            async let err = Self.read(stderr.fileHandleForReading, limit: Self.stderrTail, keepingEnd: true)
            let status = await exit.wait()
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

    /// Reads `handle` to its end on a background thread, keeping at most `limit` bytes: the first
    /// ones, calling `overflow` once when there are more, or the last ones if `keepingEnd`.
    /// Reading goes on to the end either way, so the writer never blocks on a full pipe.
    private static func read(_ handle: FileHandle, limit: Int, keepingEnd: Bool = false,
                             overflow: (@Sendable () -> Void)? = nil) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let size = 64 << 10
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
                defer { buffer.deallocate() }
                var data = Data()
                var overflowed = false
                while true {
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

    private static func realPath(_ url: URL) -> URL {
        guard let resolved = realpath(url.path, nil) else { return url }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }
}

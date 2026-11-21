import Foundation
import os

public enum DocumentConversionError: Error, Equatable {
    /// The bundled Python, or the `pagecapture-ocr` helper a scanned PDF needs, is not where it
    /// should be (e.g. running from `swift run` without a built app).
    case runtimeMissing(URL)
    /// The conversion took longer than the converter's timeout and was stopped.
    case timedOut
    /// MarkItDown or the OCR helper failed. `message` is the end of what it wrote to stderr (about
    /// 2 KB), e.g. `FileConversionException: …`, with the runtime and work directory paths
    /// replaced by `<runtime>` and `<work>`.
    case failed(status: Int32, message: String)
    /// The Markdown was longer than the converter's `maxOutputBytes`; the conversion was stopped.
    case outputTooLarge
    /// A PDF without text that OCR could not open: damaged, not a PDF, locked, or without pages.
    case unreadable
    /// A PDF without text on which OCR found no text either.
    case noTextFound
    /// The input is not a regular file (a directory, a package, a device, …).
    case notAFile
    /// The input is larger than the converter's `maxInputBytes`.
    case inputTooLarge
    /// The input could not be read or copied. Carries no path and no system error, which name the user's files.
    case unreadableInput
}

/// Converts one local file (PDF, DOCX, PPTX, XLSX, HTML, …) to Markdown with the bundled MarkItDown.
///
/// The file is untrusted (downloaded from the web), so it never reaches MarkItDown in place: it is
/// copied into a private work directory under a fixed name, and Python runs in a sandbox that
/// allows little more than reading the runtime and the system libraries and writing in that
/// directory (`sandboxProfile`), with a minimal environment of its own. A PDF without text (a
/// scan) then goes to the bundled `pagecapture-ocr` helper, in a sandbox of its own
/// (`ocrSandboxProfile`): the app's own process never decodes the file. The work directory is
/// deleted afterwards, whatever happened.
public struct DocumentConverter: Sendable {
    /// `markitdown/bin/python3` of the bundled runtime.
    public var pythonURL: URL
    /// How long one MarkItDown run may take before it is stopped.
    public var timeout: Duration
    /// The longest Markdown accepted, in bytes, from MarkItDown and from the OCR helper.
    public var maxOutputBytes: Int
    /// The largest input file accepted, in bytes.
    public var maxInputBytes: Int
    /// The `pagecapture-ocr` helper that reads scanned PDFs.
    public var ocrHelperURL: URL
    /// How long the OCR helper may take before it is stopped; a budget of its own, on top of `timeout`.
    public var ocrTimeout: Duration
    /// For tests: called with the copy of a `.pdf` whose conversion succeeded but produced no text,
    /// instead of running `ocrHelperURL`; what it returns is the result. The copy is deleted once
    /// it returns.
    public var pdfFallback: (@Sendable (URL) async throws -> String)?

    /// Where the work directories are made. Tests use one with spaces and quotes in its path.
    var temporaryRoot = FileManager.default.temporaryDirectory
    /// Called once each sandboxed process is running (Python, then the OCR helper if it runs),
    /// with its pid (also its process group) and its work directory. For tests.
    var onLaunch: (@Sendable (pid_t, URL) -> Void)?
    /// The sandbox profile Python runs under. Tests use a looser one to check what happens when
    /// Python can start processes, which `sandboxProfile` denies.
    var profile = DocumentConverter.sandboxProfile

    public init(
        pythonURL: URL = DocumentConverter.bundledPythonURL,
        timeout: Duration = .seconds(120),
        maxOutputBytes: Int = 50 << 20,
        maxInputBytes: Int = 500 << 20,
        ocrHelperURL: URL = DocumentConverter.bundledOCRHelperURL,
        ocrTimeout: Duration = .seconds(300),
        pdfFallback: (@Sendable (URL) async throws -> String)? = nil
    ) {
        self.pythonURL = pythonURL
        self.timeout = timeout
        self.maxOutputBytes = maxOutputBytes
        self.maxInputBytes = maxInputBytes
        self.ocrHelperURL = ocrHelperURL
        self.ocrTimeout = ocrTimeout
        self.pdfFallback = pdfFallback
    }

    /// `markitdown/bin/python3` in `Contents/Helpers` of the app (a link to `Contents/Resources/markitdown`).
    public static var bundledPythonURL: URL {
        Tools.bundledHelpersDirectory.appendingPathComponent("markitdown/bin/python3")
    }

    /// `pagecapture-ocr` in `Contents/Helpers` of the app.
    public static var bundledOCRHelperURL: URL {
        Tools.bundledHelpersDirectory.appendingPathComponent("pagecapture-ocr")
    }

    /// The Markdown for the file at `url`.
    public func markdown(forFile url: URL) async throws -> String {
        try Self.checkExecutable(pythonURL)
        return try await withWorkDirectory { directory in
            let fileExtension = Self.sanitisedExtension(url.pathExtension)
            let copy = directory.appendingPathComponent(fileExtension.isEmpty ? "input" : "input.\(fileExtension)")
            try copyInput(url, to: copy)
            let result = try await runSandboxed(pythonRun(Self.convertScript, arguments: [copy.path]), in: directory)
            guard result.status == 0 else { throw result.failure }
            let markdown = String(decoding: result.output, as: UTF8.self)
            guard fileExtension == "pdf", markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return markdown
            }
            if let pdfFallback { return try await pdfFallback(copy) }
            return try await recognise(copy, in: directory)
        }
    }

    /// Copies the regular file `url` (after resolving symlinks) to `copy`, within `maxInputBytes`.
    private func copyInput(_ url: URL, to copy: URL) throws {
        let source = url.resolvingSymlinksInPath()
        let values: URLResourceValues
        do {
            values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        } catch {
            throw DocumentConversionError.unreadableInput
        }
        guard values.isRegularFile == true else { throw DocumentConversionError.notAFile }
        guard (values.fileSize ?? 0) <= maxInputBytes else { throw DocumentConversionError.inputTooLarge }
        do {
            try FileManager.default.copyItem(at: source, to: copy)
        } catch {
            throw DocumentConversionError.unreadableInput
        }
    }

    /// Runs a Python snippet exactly the way `markdown(forFile:)` runs MarkItDown, in a work
    /// directory of its own, and returns its stdout. For tests of the sandbox and the timeout.
    func runScript(_ script: String, arguments: [String] = []) async throws -> String {
        try Self.checkExecutable(pythonURL)
        return try await withWorkDirectory { directory in
            let result = try await runSandboxed(pythonRun(script, arguments: arguments), in: directory)
            guard result.status == 0 else { throw result.failure }
            return String(decoding: result.output, as: UTF8.self)
        }
    }

    /// Runs the OCR helper with `arguments` exactly the way `markdown(forFile:)` runs it on a scan,
    /// in a work directory of its own, and returns its exit status and stdout. For tests of the
    /// helper's sandbox (with its debug build's `--probe-…` arguments) and timeout.
    func runOCRHelper(arguments: [String]) async throws -> (status: Int32, output: String) {
        try Self.checkExecutable(ocrHelperURL)
        return try await withWorkDirectory { directory in
            let result = try await runSandboxed(ocrRun(arguments: arguments), in: directory)
            return (result.status, String(decoding: result.output, as: UTF8.self))
        }
    }

    // MARK: - OCR

    /// The Markdown the OCR helper reads from `copy`, a PDF in the work directory `directory`.
    /// The helper's exit statuses are listed in `Sources/PageCaptureOCR/main.swift`.
    private func recognise(_ copy: URL, in directory: URL) async throws -> String {
        try Self.checkExecutable(ocrHelperURL)
        let result = try await runSandboxed(ocrRun(arguments: [copy.path]), in: directory)
        switch (result.exited, result.status) {
        case (true, 0): return String(decoding: result.output, as: UTF8.self)
        case (true, 3): throw DocumentConversionError.unreadable
        case (true, 4): throw DocumentConversionError.noTextFound
        default: throw result.failure
        }
    }

    /// Denies everything but what OCR of a PDF in the work directory needs: running the helper
    /// (`HELPER`, its real path) and reading it, its directory itself (`HELPER_DIR`: without it
    /// the helper has no main bundle and CoreImage crashes reading its defaults), the work
    /// directory (`WORK_DIR`), `/`, the system libraries and ICU's data (text recognition
    /// collates with it); writing in the work directory and to /dev/null; reading sysctls; and
    /// opening IOSurfaces (Vision always draws into IOSurface-backed buffers) and the GPU's user
    /// client (on macOS 27 Vision recognises no text at all without it, even in `.fast` mode with
    /// every stage set to the CPU). The Neural Engine stays denied, which is why OCR uses `.fast`.
    /// As for Python, there is no network, no
    /// child process, no Mach service and no file of the user's, and the paths come in as
    /// parameters.
    static let ocrSandboxProfile = """
        (version 1)
        (deny default)
        (allow process-exec (literal (param "HELPER")))
        (allow file-read*
            (literal "/") (subpath "/System") (subpath "/usr/lib") (literal "/dev/null")
            (literal (param "HELPER")) (literal (param "HELPER_DIR")) (subpath (param "WORK_DIR")))
        (allow file-write* (subpath (param "WORK_DIR")) (literal "/dev/null"))
        (allow sysctl-read)
        (allow iokit-open-user-client (iokit-user-client-class "IOSurfaceRootUserClient"))
        (allow iokit-open-user-client (iokit-user-client-class "AGXDeviceUserClient"))
        (allow file-read* (subpath "/usr/share/icu"))
        """

    // MARK: - Sandboxed run

    /// Converts `sys.argv[1]`, a local file, and writes the Markdown to stdout as UTF-8. Only
    /// `convert_local`: MarkItDown never gets a URL or a stream to fetch. A failure prints only
    /// `ExceptionName: message` to stderr, never a traceback, whose frames hold the runtime's path.
    static let convertScript = """
        import sys
        try:
            from markitdown import MarkItDown
            result = MarkItDown(enable_plugins=False).convert_local(sys.argv[1])
            sys.stdout.buffer.write((result.text_content or "").encode("utf-8"))
        except Exception as e:
            sys.stderr.write(type(e).__name__ + ": " + str(e) + "\\n")
            sys.exit(1)
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

    /// One program to run under `sandbox-exec`: what `runSandboxed` needs besides the work directory.
    private struct SandboxedProgram {
        /// The real path: `sandbox-exec` executes it, and the profile allows it by that path.
        var executable: URL
        var arguments: [String]
        var profile: String
        /// The profile's parameters (`-D NAME=value`) besides `WORK_DIR`, which is always set.
        var parameters: KeyValuePairs<String, String>
        /// The whole environment, besides `HOME` and `TMPDIR` (the work directory) and `PATH` and `LANG`.
        var environment: [String: String] = [:]
        var timeout: Duration
        /// Further paths (besides the profile's `RUNTIME`) that name the runtime, e.g. through a link.
        var runtimeAliases: [String] = []

        /// The paths a failure message must not show, longest first, with their placeholders.
        func redactions(workDirectory: URL) -> [(path: String, placeholder: String)] {
            let work = workDirectory.path
            var paths = [(work, "<work>")]
            if work.hasPrefix("/private/") { paths.append((String(work.dropFirst("/private".count)), "<work>")) }
            let runtime = parameters.first { $0.key == "RUNTIME" }?.value
            paths += ([runtime].compactMap { $0 } + runtimeAliases).map { ($0, "<runtime>") }
            return paths.sorted { $0.0.count > $1.0.count }.map { (path: $0.0, placeholder: $0.1) }
        }
    }

    /// What a sandboxed program that ran to its end (not stopped) did.
    private struct SandboxedResult {
        /// The exit status, or the signal that ended it if `exited` is false.
        var status: Int32
        var exited: Bool
        var output: Data
        var errors: Data
        /// Paths to replace in the message, with what replaces them.
        var redactions: [(path: String, placeholder: String)] = []

        /// `failed(status:message:)` with the end of stderr, without the runtime and work paths.
        var failure: DocumentConversionError {
            var message = String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            for (path, placeholder) in redactions where !path.isEmpty {
                message = message.replacingOccurrences(of: path, with: placeholder)
            }
            return .failed(status: status, message: message.isEmpty ? "Exited with status \(status)" : message)
        }
    }

    /// `python3 -I -B -c script arguments…` under `profile`.
    private func pythonRun(_ script: String, arguments: [String]) -> SandboxedProgram {
        // The real path: the sandbox matches it, and the app's `Helpers/markitdown` is a link.
        let python = Self.realPath(pythonURL, isDirectory: false)
        let runtime = python.deletingLastPathComponent().deletingLastPathComponent()
        return SandboxedProgram(
            executable: python,
            arguments: ["-I", "-B", "-c", script] + arguments,
            profile: profile,
            parameters: ["RUNTIME": runtime.path, "PYTHON": python.path],
            environment: ["PYTHONDONTWRITEBYTECODE": "1", "PYTHONIOENCODING": "utf-8"],
            timeout: timeout,
            runtimeAliases: [pythonURL.deletingLastPathComponent().deletingLastPathComponent().path])
    }

    /// `pagecapture-ocr arguments…` under `ocrSandboxProfile`.
    private func ocrRun(arguments: [String]) -> SandboxedProgram {
        let helper = Self.realPath(ocrHelperURL, isDirectory: false)
        return SandboxedProgram(
            executable: helper,
            arguments: arguments,
            profile: Self.ocrSandboxProfile,
            parameters: ["HELPER": helper.path, "HELPER_DIR": helper.deletingLastPathComponent().path],
            timeout: ocrTimeout)
    }

    /// How much of the end of stderr goes into `failed(status:message:)`.
    private static let stderrTail = 2048
    /// How long the output is still read once the program has exited and its process group is
    /// killed. Only a process that left the group can hold the pipes open that long.
    private static let drainTime: Duration = .seconds(1)

    private static func checkExecutable(_ url: URL) throws {
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw DocumentConversionError.runtimeMissing(url)
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

    /// Runs `program` under `sandbox-exec` in `directory` and returns what it did. Stops it (its
    /// whole process group) on its timeout, when stdout passes `maxOutputBytes`, or when the
    /// calling task is cancelled, and throws `timedOut`, `outputTooLarge` or `CancellationError`.
    /// Once the program has exited, kills what is left in its group and reads the output for at
    /// most `drainTime` more, so it always returns.
    private func runSandboxed(_ program: SandboxedProgram, in directory: URL) async throws -> SandboxedResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-D", "WORK_DIR=\(directory.path)"]
            + program.parameters.flatMap { ["-D", "\($0.key)=\($0.value)"] }
            + ["-p", program.profile, program.executable.path] + program.arguments
        process.environment = program.environment.merging([
            "PATH": "/usr/bin:/bin",
            "HOME": directory.path,
            "TMPDIR": directory.path,
            "LANG": "en_US.UTF-8",
        ]) { _, fixed in fixed }
        process.currentDirectoryURL = directory
        let stdout = Pipe(), stderr = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        let exit = ExitStatus()
        let running = RunningProcess()
        let exitedNormally = OSAllocatedUnfairLock(initialState: false)
        process.terminationHandler = { process in
            running.reaped()
            let exited = process.terminationReason == .exit
            exitedNormally.withLock { $0 = exited }
            exit.exited(process.terminationStatus)
        }
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let tooLarge = OSAllocatedUnfairLock(initialState: false)
        let readingStopped = OSAllocatedUnfairLock(initialState: false)
        let (timeout, maxOutputBytes, onLaunch) = (program.timeout, maxOutputBytes, onLaunch)

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
            // Nothing the program started may outlive it, and only what left its group can still
            // hold the pipes open: read them for `drainTime` at most.
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
        return SandboxedResult(status: status, exited: exitedNormally.withLock { $0 }, output: output, errors: errors,
                               redactions: program.redactions(workDirectory: directory))
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

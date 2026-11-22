import Foundation
import os

public enum DocumentConversionError: Error, Equatable {
    /// The bundled Python, or the `pagecapture-ocr` helper a scanned PDF needs, is not where it
    /// should be (e.g. running from `swift run` without a built app).
    case runtimeMissing(URL)
    /// The conversion took longer than the converter's timeout and was stopped.
    case timedOut
    /// MarkItDown or the OCR helper exited with a failure status. `message` is the end of what it
    /// wrote to stderr (about 2 KB), e.g. `FileConversionException: …`, with the runtime, work
    /// directory and helper paths replaced by `<runtime>`, `<work>` and `<helpers>`.
    case failed(status: Int32, message: String)
    /// MarkItDown or the OCR helper was ended by `signal` (SIGTERM from `Tools.stopAllRunning`, a
    /// crash, …) instead of exiting. `message` is as for `failed`, or `Stopped by signal N`.
    case stopped(signal: Int32, message: String)
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
    /// Where the work directories are made. Tests use one with spaces and quotes in its path.
    var temporaryRoot = FileManager.default.temporaryDirectory
    /// Called once each sandboxed process is running (Python, then the OCR helper if it runs),
    /// with its pid (also its process group) and its work directory. For tests.
    var onLaunch: (@Sendable (pid_t, URL) -> Void)?
    /// The sandbox profile Python runs under. Tests use a looser one to check what happens when
    /// Python can start processes, which `sandboxProfile` denies.
    var profile = DocumentConverter.sandboxProfile
    /// For tests: called with the copy of a `.pdf` whose conversion succeeded but produced no text,
    /// instead of running `ocrHelperURL`; what it returns is the result. The copy is deleted once
    /// it returns.
    var pdfFallback: (@Sendable (URL) async throws -> String)?
    /// The OCR helper's arguments for the copy of a scan. Tests replace them, e.g. with a debug
    /// build's `--probe-…` arguments, to see how the helper's ending is reported.
    var ocrArguments: @Sendable (URL) -> [String] = { [$0.path] }

    public init(
        pythonURL: URL = DocumentConverter.bundledPythonURL,
        timeout: Duration = .seconds(120),
        maxOutputBytes: Int = 50 << 20,
        maxInputBytes: Int = 500 << 20,
        ocrHelperURL: URL = DocumentConverter.bundledOCRHelperURL,
        ocrTimeout: Duration = .seconds(300)
    ) {
        self.pythonURL = pythonURL
        self.timeout = timeout
        self.maxOutputBytes = maxOutputBytes
        self.maxInputBytes = maxInputBytes
        self.ocrHelperURL = ocrHelperURL
        self.ocrTimeout = ocrTimeout
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
            guard result.exited, result.status == 0 else { throw result.failure }
            let markdown = String(decoding: result.output, as: UTF8.self)
            guard fileExtension == "pdf", markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return markdown
            }
            if let pdfFallback { return try await pdfFallback(copy) }
            return try await recognise(copy, in: directory)
        }
    }

    /// The Markdown for `html`, a captured page's semantic HTML (`markdown.js`), the way
    /// `MarkdownExporter` wants it (`pageScript`). Runs exactly like `markdown(forFile:)`, on
    /// `input.html` written in the work directory, without the PDF fallback.
    func markdown(forCapturedPageHTML html: String) async throws -> String {
        try Self.checkExecutable(pythonURL)
        return try await withWorkDirectory { directory in
            let file = directory.appendingPathComponent("input.html")
            do {
                try Data(html.utf8).write(to: file, options: .withoutOverwriting)
            } catch {
                throw DocumentConversionError.unreadableInput
            }
            let result = try await runSandboxed(pythonRun(Self.pageScript, arguments: [file.path]), in: directory)
            guard result.exited, result.status == 0 else { throw result.failure }
            return String(decoding: result.output, as: UTF8.self)
        }
    }

    /// Copies the data of the regular file `url` (after resolving symlinks) to the new file `copy`,
    /// within `maxInputBytes`. Only the bytes, with mode 0600: no flags (a Finder-locked file's
    /// `uchg` would keep the work directory from being deleted) and no extended attributes. The
    /// size is checked before, and again while copying, in case the file grew in between.
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
        try Self.copyData(of: source, to: copy, limit: maxInputBytes)
    }

    /// Copies the bytes of `source` to `destination`, a file it creates, and throws `inputTooLarge`
    /// as soon as more than `limit` bytes were read. `source` is opened without following a link
    /// and without blocking (it may have been replaced by a link or a FIFO since it was checked),
    /// and must still be a regular file.
    private static func copyData(of source: URL, to destination: URL, limit: Int) throws {
        let input = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard input >= 0 else { throw DocumentConversionError.unreadableInput }
        defer { close(input) }
        var info = stat()
        guard fstat(input, &info) == 0 else { throw DocumentConversionError.unreadableInput }
        guard info.st_mode & S_IFMT == S_IFREG else { throw DocumentConversionError.notAFile }
        let output = open(destination.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw DocumentConversionError.unreadableInput }
        defer { close(output) }

        let size = 1 << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { buffer.deallocate() }
        var total = 0
        while true {
            let count = Darwin.read(input, buffer, size)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw DocumentConversionError.unreadableInput }
            if count == 0 { return }
            total += count
            guard total <= limit else { throw DocumentConversionError.inputTooLarge }
            var written = 0
            while written < count {
                let result = Darwin.write(output, buffer + written, count - written)
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw DocumentConversionError.unreadableInput }
                written += result
            }
        }
    }

    /// Runs a Python snippet exactly the way `markdown(forFile:)` runs MarkItDown, in a work
    /// directory of its own, and returns its stdout. For tests of the sandbox and the timeout.
    func runScript(_ script: String, arguments: [String] = []) async throws -> String {
        try Self.checkExecutable(pythonURL)
        return try await withWorkDirectory { directory in
            let result = try await runSandboxed(pythonRun(script, arguments: arguments), in: directory)
            guard result.exited, result.status == 0 else { throw result.failure }
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
        let result = try await runSandboxed(ocrRun(arguments: ocrArguments(copy)), in: directory)
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

    /// `convertScript` for a captured page (`markdown(forCapturedPageHTML:)`), with the options
    /// SPEC "Saving" needs: a line break is a backslash (MarkItDown strips trailing spaces), text
    /// that Markdown would read as syntax (`|`, `<tag>`, `1.`, `#`, …) is escaped, bullets are `-`,
    /// a code block keeps its `language-…` class, and `mailto:` and `tel:` links stay links
    /// (MarkItDown keeps only http, https and file links; never `javascript:`).
    static let pageScript = """
        import sys
        try:
            import re
            import markdownify
            from markitdown import MarkItDown
            from markitdown.converters._markdownify import _CustomMarkdownify

            _convert_a = _CustomMarkdownify.convert_a

            def convert_a(self, el, text, *args, **kwargs):
                scheme, colon, _ = (el.get("href") or "").partition(":")
                if colon and scheme.lower() in ("mailto", "tel") and el.find_parent("pre") is None:
                    return markdownify.MarkdownConverter.convert_a(self, el, text, *args, **kwargs)
                return _convert_a(self, el, text, *args, **kwargs)

            _CustomMarkdownify.convert_a = convert_a

            special = re.compile(r"[\\\\`*_\\[\\]]|<(?=[A-Za-z/!?])")
            block_start = re.compile(r"^(\\s*)(#{1,6}(?:\\s|$)|>|(?:-+|=+|\\+)(?:\\s|$))")
            list_start = re.compile(r"^(\\s*\\d{1,9})([.)](?:\\s|$))")
            inline_only = {"h1", "h2", "h3", "h4", "h5", "h6", "td", "th"}

            def escape(self, text, parent_tags):
                text = special.sub(r"\\\\\\g<0>", text)
                if parent_tags & {"td", "th"}:
                    text = text.replace("|", "\\\\|")
                if not parent_tags & inline_only:
                    text = list_start.sub(r"\\1\\\\\\2", block_start.sub(r"\\1\\\\\\2", text))
                return text

            _CustomMarkdownify.escape = escape

            _convert_pre = _CustomMarkdownify.convert_pre

            def convert_pre(self, el, text, *args, **kwargs):
                out = _convert_pre(self, el, text, *args, **kwargs)
                fence = "`" * max([3] + [len(run) + 1 for run in re.findall("`+", text or "")])
                if fence != "```" and out.startswith("\\n\\n```") and out.endswith("```\\n\\n"):
                    out = "\\n\\n" + fence + out[5:-5] + fence + "\\n\\n"
                return out

            _CustomMarkdownify.convert_pre = convert_pre

            def code_language(el):
                for node in (el, el.find("code")):
                    for name in (node.get("class") or []) if node is not None else []:
                        if name.startswith("language-"):
                            return name[len("language-"):]
                return ""

            result = MarkItDown(enable_plugins=False).convert_local(
                sys.argv[1], newline_style="backslash", bullets="-",
                code_language_callback=code_language)
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
        /// Paths of the directory the app's helpers are in (the OCR helper's, real and as given),
        /// which `sandbox-exec` names when it cannot run one: `execvp() of '…' failed`.
        var helperDirectories: [String] = []

        /// The paths a failure message must not show, longest first, with their placeholders.
        func redactions(workDirectory: URL) -> [(path: String, placeholder: String)] {
            let work = workDirectory.path
            var paths = [(work, "<work>")]
            if work.hasPrefix("/private/") { paths.append((String(work.dropFirst("/private".count)), "<work>")) }
            let runtime = parameters.first { $0.key == "RUNTIME" }?.value
            paths += ([runtime].compactMap { $0 } + runtimeAliases).map { ($0, "<runtime>") }
            paths += helperDirectories.map { ($0, "<helpers>") }
            return paths.sorted { $0.0.count > $1.0.count }.map { (path: $0.0, placeholder: $0.1) }
        }
    }

    /// What a sandboxed program that ran to its end (not stopped by the converter) did.
    private struct SandboxedResult {
        /// The exit status, or the signal that ended it if `exited` is false.
        var status: Int32
        var exited: Bool
        var output: Data
        var errors: Data
        /// Paths to replace in the message, with what replaces them.
        var redactions: [(path: String, placeholder: String)] = []

        /// `failed(status:message:)`, or `stopped(signal:message:)` if a signal ended it, with the
        /// end of stderr, without the runtime, work and helper paths.
        var failure: DocumentConversionError {
            var message = String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            for (path, placeholder) in redactions where !path.isEmpty {
                message = message.replacingOccurrences(of: path, with: placeholder)
            }
            guard exited else {
                return .stopped(signal: status, message: message.isEmpty ? "Stopped by signal \(status)" : message)
            }
            return .failed(status: status, message: message.isEmpty ? "Exited with status \(status)" : message)
        }
    }

    /// `python3 -I -B -c script arguments…` under `profile`. `-I` implies `-E`, so Python ignores
    /// every `PYTHON…` variable and none is set: what matters is `-B`, which keeps it from writing
    /// bytecode into the runtime, and that the scripts write to `sys.stdout.buffer` as UTF-8 bytes.
    private func pythonRun(_ script: String, arguments: [String]) -> SandboxedProgram {
        // The real path: the sandbox matches it, and the app's `Helpers/markitdown` is a link.
        let python = Self.realPath(pythonURL, isDirectory: false)
        let runtime = python.deletingLastPathComponent().deletingLastPathComponent()
        return SandboxedProgram(
            executable: python,
            arguments: ["-I", "-B", "-c", script] + arguments,
            profile: profile,
            parameters: ["RUNTIME": runtime.path, "PYTHON": python.path],
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
            timeout: ocrTimeout,
            helperDirectories: [helper.deletingLastPathComponent().path, ocrHelperURL.deletingLastPathComponent().path])
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
        defer { Self.removeWorkDirectory(directory) }
        return try await body(Self.realPath(directory, isDirectory: true))
    }

    /// Deletes `directory` and everything in it. What ran in it can set flags (`uchg`, `uappnd`)
    /// on what it wrote, which keep it from being deleted: if deleting fails, clears the flags of
    /// everything in it, without following links, and tries again.
    private static func removeWorkDirectory(_ directory: URL) {
        let fm = FileManager.default
        guard (try? fm.removeItem(at: directory)) == nil else { return }
        lchflags(directory.path, 0)
        if let contents = fm.enumerator(atPath: directory.path) {
            for case let path as String in contents {
                lchflags(directory.appendingPathComponent(path).path, 0)
            }
        }
        try? fm.removeItem(at: directory)
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

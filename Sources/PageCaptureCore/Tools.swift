import Foundation

/// The command-line tools bundled in `PageCapture.app/Contents/Helpers/`.
public enum BundledTool: String, CaseIterable, Sendable {
    case ffmpeg
    case ffprobe
    case ytDlp = "yt-dlp"
    case deno

    /// The executable's file name.
    public var fileName: String { rawValue }
}

/// How a tool run ended.
public struct ToolResult: Equatable, Sendable {
    /// The exit status, or the signal number if the tool was killed by a signal.
    public var status: Int32
    public var stdout: String
    public var stderr: String

    public var succeeded: Bool { status == 0 }
}

public enum ToolError: Error, Equatable {
    /// The tool is not where it should be (e.g. running from `swift run` without a built app).
    case missing(URL)
}

/// Locates and runs the bundled tools.
///
/// ffmpeg, ffprobe and Deno run straight from the (signed, read-only) bundle. yt-dlp runs from a
/// working copy in Application Support, so `updateYtDlp()` can let it replace itself without
/// touching the app; the copy is refreshed from the bundle when the bundled one is newer.
public actor Tools {
    /// Where the bundled tools are: `Contents/Helpers` of the app, or `build/tools` in tests.
    public nonisolated let helpersDirectory: URL
    /// Holds `bin/yt-dlp`: `~/Library/Application Support/PageCapture`, or a temporary folder in tests.
    public nonisolated let supportDirectory: URL

    /// Set once the yt-dlp working copy has been checked against the bundled one in this process.
    private var ytDlpChecked = false

    public init(helpersDirectory: URL = Tools.bundledHelpersDirectory, supportDirectory: URL = Tools.defaultSupportDirectory) {
        self.helpersDirectory = helpersDirectory
        self.supportDirectory = supportDirectory
    }

    /// `Contents/Helpers` of the main bundle.
    public static var bundledHelpersDirectory: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
    }

    /// `~/Library/Application Support/PageCapture`.
    public static var defaultSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PageCapture", isDirectory: true)
    }

    /// The tool's copy in the helpers directory.
    public nonisolated func bundledURL(_ tool: BundledTool) -> URL {
        helpersDirectory.appendingPathComponent(tool.fileName)
    }

    /// `<support>/bin/yt-dlp`, the copy that actually runs.
    public nonisolated var ytDlpWorkingCopy: URL {
        supportDirectory.appendingPathComponent("bin/yt-dlp")
    }

    /// Arguments put before every yt-dlp run: ignore the user's own yt-dlp config files (they could
    /// change output names and formats under the app), and use the bundled ffmpeg and Deno.
    /// yt-dlp enables Deno by default; `--js-runtimes deno:<path>` tells it which binary.
    public nonisolated var ytDlpBaseArguments: [String] {
        [
            "--ignore-config",
            "--ffmpeg-location", bundledURL(.ffmpeg).path,
            "--js-runtimes", "deno:\(bundledURL(.deno).path)",
        ]
    }

    /// The executable to run for `tool`. For yt-dlp, this makes sure the working copy is current.
    public func executableURL(for tool: BundledTool) async throws -> URL {
        tool == .ytDlp ? try await prepareYtDlp() : try existing(bundledURL(tool))
    }

    /// Runs `tool` with `arguments` (yt-dlp also gets `ytDlpBaseArguments` first) and collects its output.
    /// `environment` entries are added to (or replace) the app's own environment.
    /// Cancelling the calling task stops the tool and anything it started (SIGTERM to its process
    /// group, SIGKILL 2 s later), then throws `CancellationError`.
    public func run(_ tool: BundledTool, arguments: [String], environment: [String: String] = [:]) async throws -> ToolResult {
        let executable = try await executableURL(for: tool)
        let fullArguments = tool == .ytDlp ? ytDlpBaseArguments + arguments : arguments
        return try await Self.runProcess(executable, arguments: fullArguments, environment: environment)
    }

    /// Runs `yt-dlp -U` on the working copy, which downloads and installs the latest release over it.
    public func updateYtDlp() async throws -> ToolResult {
        try await run(.ytDlp, arguments: ["-U"])
    }

    // MARK: - yt-dlp working copy

    /// Copies the bundled yt-dlp to the working copy if there is none yet, or if the bundled one
    /// is a newer release (a newer app) than the copy, which `-U` may already have moved past.
    func prepareYtDlp() async throws -> URL {
        let bundled = try existing(bundledURL(.ytDlp))
        let copy = ytDlpWorkingCopy
        if ytDlpChecked, FileManager.default.isExecutableFile(atPath: copy.path) { return copy }

        var replace = true
        if FileManager.default.isExecutableFile(atPath: copy.path) {
            async let bundledVersion = Self.version(of: bundled)
            async let copyVersion = Self.version(of: copy)
            if let copyVersion = try await copyVersion, let bundledVersion = try await bundledVersion {
                replace = Self.isNewer(bundledVersion, than: copyVersion)
            }
        }
        if replace { try Self.installCopy(of: bundled, at: copy) }
        ytDlpChecked = true
        return copy
    }

    /// The release `yt-dlp --version` prints (e.g. `2026.10.26`), or nil if it does not run.
    private static func version(of executable: URL) async throws -> String? {
        let result = try await runProcess(executable, arguments: ["--version"], environment: [:])
        let version = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.succeeded && !version.isEmpty ? version : nil
    }

    /// Compares yt-dlp versions (`YYYY.MM.DD`, nightlies add `.HHMMSS`) field by field as numbers.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let fields = { (v: String) in v.split(separator: ".").map { Int($0) ?? 0 } }
        return fields(b).lexicographicallyPrecedes(fields(a))
    }

    /// Copies `source` to `destination` through a temporary file, so a half-written copy never runs.
    private static func installCopy(of source: URL, at destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent)-\(UUID().uuidString)")
        try fm.copyItem(at: source, to: temporary)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
        if rename(temporary.path, destination.path) != 0 {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            try? fm.removeItem(at: temporary)
            throw error
        }
    }

    private nonisolated func existing(_ url: URL) throws -> URL {
        guard FileManager.default.isExecutableFile(atPath: url.path) else { throw ToolError.missing(url) }
        return url
    }

    // MARK: - Running

    static func runProcess(_ executable: URL, arguments: [String], environment: [String: String]) async throws -> ToolResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        let stdout = Pipe(), stderr = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        let exit = ExitStatus()
        process.terminationHandler = { exit.exited($0.terminationStatus) }
        let running = RunningProcess()

        return try await withTaskCancellationHandler {
            try process.run()
            running.launched(group: process.processIdentifier)
            // Until the output is read to the end, which also waits for whatever the tool started.
            defer { running.finished() }
            // Cancelled before the handler could see a running process.
            if Task.isCancelled { running.stop() }
            async let out = readToEnd(stdout.fileHandleForReading)
            async let err = readToEnd(stderr.fileHandleForReading)
            let status = await exit.wait()
            let result = ToolResult(
                status: status,
                stdout: String(decoding: await out, as: UTF8.self),
                stderr: String(decoding: await err, as: UTF8.self))
            try Task.checkCancellation()
            return result
        } onCancel: {
            running.stop()
        }
    }

    /// Stops every tool still running, and what they started: SIGTERM, then SIGKILL for what is
    /// left after a grace period (2 s). Blocks until then; for when the app quits.
    public static func stopAllRunning() {
        let running = RunningProcess.all
        guard !running.isEmpty else { return }
        for process in running { process.signal(SIGTERM) }
        let deadline = ContinuousClock.now + RunningProcess.gracePeriod
        while ContinuousClock.now < deadline, running.contains(where: \.isAlive) { usleep(50_000) }
        for process in running { process.signal(SIGKILL) }
    }

    private static func readToEnd(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: handle.readDataToEndOfFile()) }
        }
    }
}

/// The process group of a tool run, from launch until its output has been read to the end.
///
/// Process starts each tool as the leader of its own process group, so signalling the group also
/// reaches what the tool started (the Python child of yt-dlp's launcher, yt-dlp's ffmpeg), even
/// after the tool itself has exited. Every run in progress is listed in `all`, so the app can stop
/// them when it quits: being group leaders, they get no signal when the app exits.
final class RunningProcess: @unchecked Sendable {
    /// How long a stopped tool gets to exit after SIGTERM before SIGKILL. PyInstaller's yt-dlp
    /// only removes its `_MEI*` folder from `$TMPDIR` when it is allowed to exit.
    static let gracePeriod: Duration = .seconds(2)

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry = [ObjectIdentifier: RunningProcess]()

    static var all: [RunningProcess] { registryLock.withLock { Array(registry.values) } }

    private let lock = NSLock()
    /// The process group; 0 before launch and once the run has finished.
    private var group: pid_t = 0

    func launched(group: pid_t) {
        lock.withLock { self.group = group }
        Self.registryLock.withLock { Self.registry[ObjectIdentifier(self)] = self }
    }

    func finished() {
        lock.withLock { group = 0 }
        _ = Self.registryLock.withLock { Self.registry.removeValue(forKey: ObjectIdentifier(self)) }
    }

    /// SIGTERM to the group now, SIGKILL after `gracePeriod` if the run has not finished by then.
    func stop() {
        guard signal(SIGTERM) else { return }
        let seconds = Double(Self.gracePeriod.components.seconds)
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [self] in signal(SIGKILL) }
    }

    /// Sends `sig` to the group while the run is in progress. Returns whether it was in progress.
    @discardableResult
    func signal(_ sig: Int32) -> Bool {
        lock.withLock {
            guard group > 0 else { return false }
            if killpg(group, sig) != 0 { Darwin.kill(group, sig) }
            return true
        }
    }

    /// Whether anything in the group is still running.
    var isAlive: Bool {
        lock.withLock { group > 0 && killpg(group, 0) == 0 }
    }
}

/// The exit status, delivered once from `terminationHandler` to whoever awaits it.
private final class ExitStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var continuation: CheckedContinuation<Int32, Never>?

    func exited(_ status: Int32) {
        lock.withLock {
            self.status = status
            continuation?.resume(returning: status)
            continuation = nil
        }
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if let status { continuation.resume(returning: status) } else { self.continuation = continuation }
            }
        }
    }
}

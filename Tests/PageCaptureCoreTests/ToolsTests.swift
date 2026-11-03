import ImageIO
import XCTest
@testable import PageCaptureCore

/// Runs the real tools from `build/tools` (made by `scripts/fetch-tools.sh`) against the small
/// clips in `Fixtures/video` (made by `scripts/make-video-fixtures.sh`).
final class ToolsTests: XCTestCase {
    private static let toolsDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("build/tools", isDirectory: true)

    private var folder: URL!
    private var tools: Tools!
    private var video: URL!

    override func setUpWithError() throws {
        for tool in BundledTool.allCases
        where !FileManager.default.isExecutableFile(atPath: Self.toolsDirectory.appendingPathComponent(tool.fileName).path) {
            throw XCTSkip("Run scripts/fetch-tools.sh first: \(tool.fileName) is missing from build/tools")
        }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ToolsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        tools = Tools(helpersDirectory: Self.toolsDirectory, supportDirectory: folder.appendingPathComponent("support"))
        video = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/video", withExtension: nil))
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    // MARK: - ffmpeg / ffprobe

    func testJoinsLocalHLSWithTSSegmentsIntoMP4() async throws {
        let output = try await remuxHLS("hls-ts")
        let codecs = try await streamCodecs(output)
        XCTAssertEqual(codecs, ["h264", "aac"])
    }

    func testJoinsLocalAES128HLSIntoMP4() async throws {
        // The segments really are encrypted: on their own they are not MPEG-TS.
        let segment = try await tools.run(.ffprobe, arguments: ["-v", "error", video.appendingPathComponent("hls-aes/seg0.ts").path])
        XCTAssertFalse(segment.succeeded)

        let output = try await remuxHLS("hls-aes")
        let codecs = try await streamCodecs(output)
        XCTAssertEqual(codecs, ["h264", "aac"])
    }

    func testJoinsLocalFMP4HLSIntoMP4() async throws {
        let output = try await remuxHLS("hls-fmp4")
        let codecs = try await streamCodecs(output)
        XCTAssertEqual(codecs, ["h264", "aac"])
    }

    func testMergesVideoOnlyMP4AndAudioOnlyM4AIntoMP4() async throws {
        let output = folder.appendingPathComponent("merged.mp4")
        try await merge("video-only.mp4", "audio-only.m4a", into: output)
        let codecs = try await streamCodecs(output)
        XCTAssertEqual(codecs, ["h264", "aac"])
    }

    func testMergesWebMVideoAndAudioIntoMKVAndMP4() async throws {
        for name in ["merged.mkv", "merged.mp4"] {
            let output = folder.appendingPathComponent(name)
            try await merge("video-only.webm", "audio-only.webm", into: output)
            let codecs = try await streamCodecs(output)
            XCTAssertEqual(codecs, ["vp9", "opus"], name)
        }
    }

    func testExtractsAScaledPNGFrameFromH264HEVCAndVP9() async throws {
        for (clip, codec) in [("video-only.mp4", "h264"), ("video-hevc.mp4", "hevc"), ("video-only.webm", "vp9")] {
            let input = video.appendingPathComponent(clip)
            let codecs = try await streamCodecs(input)
            XCTAssertEqual(codecs, [codec])
            let png = folder.appendingPathComponent("\(clip).png")
            let result = try await tools.run(.ffmpeg, arguments: [
                "-nostdin", "-v", "error", "-ss", "1", "-i", input.path,
                "-frames:v", "1", "-vf", "scale=128:-2", png.path,
            ])
            XCTAssertTrue(result.succeeded, "\(clip): \(result.stderr)")
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(png as CFURL, nil), clip)
            XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.png", clip)
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), clip)
            XCTAssertEqual([image.width, image.height], [128, 96], clip)
        }
    }

    func testCancellingTheTaskKillsTheTool() async throws {
        // Plays the clip in a loop in real time for 10 s, unless killed first.
        let input = video.appendingPathComponent("video-only.mp4").path
        let tools = try XCTUnwrap(self.tools)
        let task = Task {
            try await tools.run(.ffmpeg, arguments: ["-nostdin", "-re", "-stream_loop", "-1", "-i", input, "-t", "10", "-c", "copy", "-f", "null", "-"])
        }
        try await Task.sleep(for: .milliseconds(500))
        let cancelled = ContinuousClock.now
        task.cancel()
        do {
            let result = try await task.value
            XCTFail("expected CancellationError, got \(result)")
        } catch is CancellationError {}
        XCTAssertLessThan(ContinuousClock.now - cancelled, .seconds(5))
    }

    func testCancellingKillsTheToolAndWhatItStarted() async throws {
        let (toolPid, childPid) = try await cancelStub(Self.toolWithChild)
        try await assertGone(toolPid, "tool")
        try await assertGone(childPid, "child")
    }

    /// yt-dlp (PyInstaller) only cleans up its `_MEI*` folder when it may exit on its own.
    func testCancellingAsksTheToolToExitFirst() async throws {
        let (toolPid, childPid) = try await cancelStub("""
            trap 'touch "$1/terminated"; exit 0' TERM
            """ + "\n" + Self.toolWithChild)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("pids/terminated").path))
        try await assertGone(toolPid, "tool")
        try await assertGone(childPid, "child")
    }

    func testToolThatIgnoresSIGTERMIsKilledAfterTheGracePeriod() async throws {
        let started = ContinuousClock.now
        let (toolPid, childPid) = try await cancelStub("trap '' TERM\n" + Self.toolWithChild)
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - started, .milliseconds(1900))
        try await assertGone(toolPid, "tool")
        try await assertGone(childPid, "child")
    }

    func testStopAllRunningStopsToolsWhenTheAppQuits() async throws {
        let (task, toolPid, childPid) = try await startStub(Self.toolWithChild)
        Tools.stopAllRunning()
        let result = try await task.value
        XCTAssertEqual(result.status, SIGTERM)
        try await assertGone(toolPid, "tool")
        try await assertGone(childPid, "child")
    }

    /// The tool has exited, but what it started still runs (and holds its output open).
    func testCancellingKillsWhatTheToolLeftRunning() async throws {
        let (toolPid, childPid) = try await cancelStub("""
            sleep 60 &
            echo $! > "$1/child.pid"
            echo $$ > "$1/tool.pid"
            exit 0
            """, waitForToolExit: true)
        try await assertGone(toolPid, "tool")
        try await assertGone(childPid, "child")
    }

    // MARK: - yt-dlp

    func testYtDlpRunsFromAWorkingCopyOfTheBundledOne() async throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: tools.ytDlpWorkingCopy.path))
        let result = try await tools.run(.ytDlp, arguments: ["--version"])
        XCTAssertTrue(result.succeeded, result.stderr)
        XCTAssertTrue(result.stdout.hasPrefix("20"), result.stdout)
        XCTAssertTrue(FileManager.default.contentsEqual(
            atPath: tools.ytDlpWorkingCopy.path, andPath: tools.bundledURL(.ytDlp).path))
    }

    func testYtDlpUsesTheBundledFFmpegAndDeno() async throws {
        // Without a URL yt-dlp only prints its debug header (and a usage error).
        let result = try await tools.run(.ytDlp, arguments: ["-v"])
        XCTAssertTrue(result.stderr.contains("exe versions: ffmpeg 9"), result.stderr)
        XCTAssertTrue(result.stderr.contains("JS runtimes: deno-"), result.stderr)
    }

    func testOlderWorkingCopyIsReplacedByTheBundledYtDlp() async throws {
        try installStubWorkingCopy(version: "2000.01.01")
        let result = try await tools.run(.ytDlp, arguments: ["--version"])
        XCTAssertTrue(result.succeeded, result.stderr)
        XCTAssertNotEqual(result.stdout, "2000.01.01\n")
        XCTAssertTrue(FileManager.default.contentsEqual(
            atPath: tools.ytDlpWorkingCopy.path, andPath: tools.bundledURL(.ytDlp).path))
    }

    func testNewerWorkingCopyIsKeptAndUpdateRunsItWithU() async throws {
        try installStubWorkingCopy(version: "2099.01.01")
        let result = try await tools.updateYtDlp()
        XCTAssertTrue(result.succeeded, result.stderr)
        XCTAssertTrue(result.stdout.hasPrefix("stub:"), result.stdout)
        XCTAssertTrue(result.stdout.hasSuffix(" -U\n"), result.stdout)
        XCTAssertTrue(result.stdout.contains("--ffmpeg-location \(tools.bundledURL(.ffmpeg).path)"), result.stdout)
    }

    func testYtDlpVersionOrder() {
        XCTAssertTrue(Tools.isNewer("2026.10.26", than: "2026.9.30"))
        XCTAssertTrue(Tools.isNewer("2026.10.26.123456", than: "2026.10.26"))
        XCTAssertFalse(Tools.isNewer("2026.10.26", than: "2026.10.26"))
        XCTAssertFalse(Tools.isNewer("2025.12.31", than: "2026.01.01"))
    }

    // MARK: - Deno

    func testDenoRuns() async throws {
        let result = try await tools.run(.deno, arguments: ["--version"])
        XCTAssertTrue(result.succeeded, result.stderr)
        XCTAssertTrue(result.stdout.hasPrefix("deno 2."), result.stdout)
    }

    // MARK: - Helpers

    private func remuxHLS(_ name: String) async throws -> URL {
        let output = folder.appendingPathComponent("\(name).mp4")
        let result = try await tools.run(.ffmpeg, arguments: [
            // ffmpeg's HLS demuxer only opens local files (the AES key too) with media extensions
            // unless told otherwise; the playlist is the app's own, so any name is fine.
            "-nostdin", "-v", "error", "-allowed_extensions", "ALL",
            "-i", video.appendingPathComponent("\(name)/index.m3u8").path,
            "-c", "copy", "-bsf:a", "aac_adtstoasc", output.path,
        ])
        XCTAssertTrue(result.succeeded, result.stderr)
        return output
    }

    private func merge(_ videoName: String, _ audioName: String, into output: URL) async throws {
        let result = try await tools.run(.ffmpeg, arguments: [
            "-nostdin", "-v", "error",
            "-i", video.appendingPathComponent(videoName).path, "-i", video.appendingPathComponent(audioName).path,
            "-map", "0:v:0", "-map", "1:a:0", "-c", "copy", output.path,
        ])
        XCTAssertTrue(result.succeeded, result.stderr)
    }

    /// The codec of each stream, as ffprobe reports it; the file must also last about 2 seconds.
    private func streamCodecs(_ file: URL) async throws -> [String] {
        let result = try await tools.run(.ffprobe, arguments: [
            "-v", "error", "-print_format", "json", "-show_streams", "-show_format", file.path,
        ])
        XCTAssertTrue(result.succeeded, result.stderr)
        struct Probe: Decodable {
            struct Stream: Decodable { var codec_name: String }
            struct Format: Decodable { var duration: String }
            var streams: [Stream]
            var format: Format
        }
        let probe = try JSONDecoder().decode(Probe.self, from: Data(result.stdout.utf8))
        XCTAssertEqual(Double(probe.format.duration) ?? 0, 2, accuracy: 0.2, file.lastPathComponent)
        return probe.streams.map(\.codec_name)
    }

    /// A stand-in tool that starts `sleep 60` and waits for it.
    private static let toolWithChild = """
        sleep 60 &
        echo $! > "$1/child.pid"
        echo $$ > "$1/tool.pid"
        wait
        """

    /// Runs `body` as a stand-in ffmpeg (given a folder for its pid files as `$1`), and returns the
    /// run and its pids once both are written (and the tool has exited, if asked).
    private func startStub(_ body: String, waitForToolExit: Bool = false) async throws
        -> (Task<ToolResult, Error>, pid_t, pid_t) {
        let helpers = folder.appendingPathComponent("stub-helpers", isDirectory: true)
        let pids = folder.appendingPathComponent("pids", isDirectory: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pids, withIntermediateDirectories: true)
        let stub = helpers.appendingPathComponent(BundledTool.ffmpeg.fileName)
        try ("#!/bin/sh\n" + body + "\n").write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let tools = Tools(helpersDirectory: helpers, supportDirectory: folder.appendingPathComponent("support"))

        let task = Task { try await tools.run(.ffmpeg, arguments: [pids.path]) }
        let readPid = { (name: String) -> pid_t? in
            (try? String(contentsOf: pids.appendingPathComponent(name), encoding: .utf8))
                .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        let deadline = ContinuousClock.now + .seconds(5)
        var found: (pid_t, pid_t)?
        while found == nil, ContinuousClock.now < deadline {
            if let tool = readPid("tool.pid"), let child = readPid("child.pid"),
               !waitForToolExit || !Self.isRunning(tool) {
                found = (tool, child)
            } else {
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        let (toolPid, childPid) = try XCTUnwrap(found, "the stub did not start")
        XCTAssertTrue(Self.isRunning(childPid))
        return (task, toolPid, childPid)
    }

    /// Cancels a `startStub` run, which must end within 5 s with `CancellationError`; returns the pids.
    private func cancelStub(_ body: String, waitForToolExit: Bool = false) async throws -> (pid_t, pid_t) {
        let (task, toolPid, childPid) = try await startStub(body, waitForToolExit: waitForToolExit)
        let cancelled = ContinuousClock.now
        task.cancel()
        do {
            let result = try await task.value
            XCTFail("expected CancellationError, got \(result)")
        } catch is CancellationError {}
        XCTAssertLessThan(ContinuousClock.now - cancelled, .seconds(5))
        return (toolPid, childPid)
    }

    private static func isRunning(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    /// Waits up to 2 s for `pid` to be gone (reaped by its parent or launchd).
    private func assertGone(_ pid: pid_t, _ what: String) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while Self.isRunning(pid), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(Self.isRunning(pid), "\(what) \(pid) still runs")
        if Self.isRunning(pid) { kill(pid, SIGKILL) }
    }

    /// A shell script in place of the working copy: prints `version` for `--version`, else its arguments.
    private func installStubWorkingCopy(version: String) throws {
        let copy = tools.ytDlpWorkingCopy
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        let script = """
            #!/bin/sh
            case " $* " in *" --version "*) echo \(version) ;; *) echo "stub: $*" ;; esac
            """
        try script.write(to: copy, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copy.path)
    }
}

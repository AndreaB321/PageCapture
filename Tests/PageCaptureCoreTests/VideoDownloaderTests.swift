import Network
import XCTest
@testable import PageCaptureCore

/// Runs VideoDownloader against a local HTTP server (URLSession does not use the web view's
/// `pctest://` handler) serving `Fixtures/video`, with the real tools from `build/tools`.
final class VideoDownloaderTests: XCTestCase {
    private static let toolsDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("build/tools", isDirectory: true)

    private var folder: URL!
    private var tools: Tools!
    private var video: URL!
    private var server: FixtureHTTPServer!

    override func setUp() async throws {
        for tool in BundledTool.allCases
        where !FileManager.default.isExecutableFile(atPath: Self.toolsDirectory.appendingPathComponent(tool.fileName).path) {
            throw XCTSkip("Run scripts/fetch-tools.sh first: \(tool.fileName) is missing from build/tools")
        }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("VideoDownloaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("capture"), withIntermediateDirectories: true)
        tools = Tools(helpersDirectory: Self.toolsDirectory, supportDirectory: folder.appendingPathComponent("support"))
        video = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/video", withExtension: nil))
        server = try await FixtureHTTPServer.start()
    }

    override func tearDown() async throws {
        server?.stop()
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    private var capture: URL { folder.appendingPathComponent("capture") }
    private var temporaryRoot: URL { folder.appendingPathComponent("tmp") }
    private var page: String { server.url("/page.html") }
    private var sessionCookie: HTTPCookie {
        HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/", .name: "session", .value: "s3cret"])!
    }

    private func fixture(_ path: String) throws -> Data { try Data(contentsOf: video.appendingPathComponent(path)) }

    private func download(_ videos: [CapturedVideo], posters: [Int: String] = [:], cookies: [HTTPCookie] = [],
                          timeLimit: Duration = VideoDownloader.defaultTimeLimit) async -> [Int: VideoLink] {
        await VideoDownloader.download(videos, into: capture, posters: posters, cookies: cookies, tools: tools,
                                       timeLimit: timeLimit, temporaryRoot: temporaryRoot)
    }

    /// Only final files were written into the capture folder, and no work folder is left.
    private func assertNothingTemporaryLeft(file: StaticString = #filePath, line: UInt = #line) throws {
        let written = FileManager.default.subpaths(atPath: capture.path) ?? []
        XCTAssertEqual(written.filter { !$0.hasPrefix("videos") && !$0.hasPrefix("images") }, [], file: file, line: line)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporaryRoot.path), [], file: file, line: line)
    }

    // MARK: - Direct files

    func testDirectFileIsDownloadedWithCookieAndReferer() async throws {
        server.route("/media/clip.mp4", try fixture("video-only.mp4"), requiresCookie: "session=s3cret")
        let clip = CapturedVideo(index: 0, kind: .file, url: server.url("/media/clip.mp4"), pageURL: page,
                                 frameOrigin: server.url(""), title: "My: Clip")

        let refused = await download([clip])
        XCTAssertEqual(refused[0]?.outcome, .failed("HTTP 403 for clip.mp4"))
        XCTAssertEqual(refused[0]?.href, clip.url)

        let links = await download([clip], posters: [0: "001-poster.png"], cookies: [sessionCookie])
        XCTAssertEqual(links[0], VideoLink(href: "videos/001-My- Clip.mp4", posterFile: "images/001-poster.png",
                                           title: "My: Clip", outcome: .saved))
        XCTAssertEqual(server.requests.last?.headers["referer"], page)
        let codecs = try await streamCodecs(capture.appendingPathComponent("videos/001-My- Clip.mp4"))
        XCTAssertEqual(codecs, ["h264"])
        try assertNothingTemporaryLeft()
    }

    func testRequestsCarryOnlyTheCookiesForTheirURL() async throws {
        server.route("/media/clip.mp4", try fixture("video-only.mp4"), requiresCookie: "session=s3cret")
        let clip = CapturedVideo(index: 0, kind: .file, url: server.url("/media/clip.mp4"), pageURL: page, frameOrigin: "")
        let others = [
            HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/elsewhere", .name: "path", .value: "p"])!,
            HTTPCookie(properties: [.domain: ".example.com", .path: "/", .name: "other", .value: "o"])!,
        ]

        let links = await download([clip], posters: [0: "001-poster.png"], cookies: [sessionCookie] + others)
        XCTAssertEqual(links[0]?.outcome, .saved)
        XCTAssertEqual(server.requests.last?.headers["cookie"], "session=s3cret")
    }

    func testSavedVideoWithoutPosterGetsAFrame() async throws {
        server.route("/media/clip", try fixture("video-only.mp4"), contentType: "video/mp4")
        let clip = CapturedVideo(index: 2, kind: .file, url: server.url("/media/clip"), pageURL: page, frameOrigin: "")

        let links = await download([clip])
        XCTAssertEqual(links[2], VideoLink(href: "videos/003-clip.mp4", posterFile: "images/video-003-clip.png",
                                           title: "Video 3", outcome: .saved))
        let png = try Data(contentsOf: capture.appendingPathComponent("images/video-003-clip.png"))
        XCTAssertEqual(png.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]))
    }

    // MARK: - HLS

    /// A master playlist with a low and a high variant; the high one names an audio group with a
    /// non-default and a default rendition. Everything is AES-128 encrypted, and the key needs the cookie.
    func testHLSMasterSavesBestVariantWithItsDefaultAudioRendition() async throws {
        let split = "hls-split"
        server.route("/hls/master.m3u8", Data("""
            #EXTM3U
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="Commentary",DEFAULT=NO,URI="missing/commentary.m3u8"
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="Main, English",DEFAULT=YES,URI="audio/index.m3u8"
            #EXT-X-STREAM-INF:BANDWIDTH=100000,CODECS="avc1.42c00a,mp4a.40.2",AUDIO="aud"
            missing/low.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=900000,CODECS="avc1.42c00a,mp4a.40.2",AUDIO="aud"
            video/index.m3u8

            """.utf8))
        // Segment and init URLs without extensions, as many CDNs serve them.
        let videoPlaylist = String(decoding: try fixture("\(split)/video/index.m3u8"), as: UTF8.self)
            .replacingOccurrences(of: "seg0.m4s", with: "seg/0?sig=a").replacingOccurrences(of: "seg1.m4s", with: "seg/1?sig=b")
            .replacingOccurrences(of: "init.mp4", with: "init")
        server.route("/hls/video/index.m3u8", Data(videoPlaylist.utf8))
        server.route("/hls/video/seg/0", try fixture("\(split)/video/seg0.m4s"))
        server.route("/hls/video/seg/1", try fixture("\(split)/video/seg1.m4s"))
        server.route("/hls/video/init", try fixture("\(split)/video/init.mp4"))
        for name in ["index.m3u8", "seg0.ts", "seg1.ts", "seg2.ts"] {
            server.route("/hls/audio/\(name)", try fixture("\(split)/audio/\(name)"))
        }
        server.route("/hls/key.bin", try fixture("\(split)/key.bin"), requiresCookie: "session=s3cret")
        let stream = CapturedVideo(index: 0, kind: .hls, url: server.url("/hls/master.m3u8"), pageURL: page,
                                   frameOrigin: "", title: "Stream")

        let links = await download([stream], posters: [0: "001-poster.jpg"], cookies: [sessionCookie])
        XCTAssertEqual(links[0], VideoLink(href: "videos/001-Stream.mp4", posterFile: "images/001-poster.jpg",
                                           title: "Stream", outcome: .saved))
        let codecs = try await streamCodecs(capture.appendingPathComponent("videos/001-Stream.mp4"))
        XCTAssertEqual(codecs, ["h264", "aac"])
        let paths = server.requests.map(\.path)
        XCTAssertFalse(paths.contains { $0.contains("missing") }, "\(paths)")
        XCTAssertEqual(paths.filter { $0 == "/hls/key.bin" }.count, 1)
        XCTAssertTrue(server.requests.allSatisfy { $0.headers["referer"] == page })
        try assertNothingTemporaryLeft()
    }

    func testSampleAESStreamIsProtectedAndNeverDownloaded() async throws {
        server.route("/drm/index.m3u8", Data("""
            #EXTM3U
            #EXT-X-TARGETDURATION:1
            #EXT-X-KEY:METHOD=SAMPLE-AES,URI="key.bin",IV=0x00000000000000000000000000000000
            #EXTINF:1.0,
            seg0.ts
            #EXTINF:1.0,
            seg1.ts
            #EXT-X-ENDLIST

            """.utf8))
        for name in ["key.bin", "seg0.ts", "seg1.ts"] { server.route("/drm/\(name)", try fixture("hls-aes/\(name)")) }
        let stream = CapturedVideo(index: 0, kind: .hls, url: server.url("/drm/index.m3u8"), pageURL: page, frameOrigin: "")

        let links = await download([stream])
        XCTAssertEqual(links[0], VideoLink(href: stream.url, posterFile: nil, title: "Video 1", outcome: .protected))
        XCTAssertEqual(server.requests.map(\.path), ["/drm/index.m3u8"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: capture.appendingPathComponent("videos").path))
    }

    func testLiveStreamFailsAndOthersStillRun() async throws {
        server.route("/live/index.m3u8", Data("""
            #EXTM3U
            #EXT-X-TARGETDURATION:1
            #EXT-X-MEDIA-SEQUENCE:7
            #EXTINF:1.0,
            seg7.ts

            """.utf8))
        let live = CapturedVideo(index: 0, kind: .hls, url: server.url("/live/index.m3u8"), pageURL: page, frameOrigin: "")
        let drm = CapturedVideo(index: 1, kind: .drm, url: "https://example.com/drm", pageURL: page, frameOrigin: "")
        let unknown = CapturedVideo(index: 2, kind: .unknown, url: page, pageURL: page, frameOrigin: "")
        let dash = CapturedVideo(index: 3, kind: .dash, url: "https://example.com/a.mpd", pageURL: page, frameOrigin: "")

        let links = await download([live, drm, unknown, dash])
        XCTAssertEqual(links[0]?.outcome, .failed("Live streams cannot be saved"))
        XCTAssertEqual(links[0]?.href, live.url)
        XCTAssertEqual(links[1]?.outcome, .protected)
        XCTAssertEqual(links[2], VideoLink(href: page, posterFile: nil, title: "Video 3", outcome: .failed("No video source was found")))
        XCTAssertEqual(links[3]?.outcome, .failed("DASH streams are not supported"))
        XCTAssertEqual(server.requests.map(\.path), ["/live/index.m3u8"])
    }

    // MARK: - yt-dlp

    func testYouTubeRunsYtDlpWithReferer() async throws {
        let record = try installYtDlpStub()
        let embed = CapturedVideo(index: 0, kind: .youtube, url: "https://www.youtube.com/embed/abc123", pageURL: page,
                                  frameOrigin: "https://www.youtube.com", title: "Talk")

        let links = await download([embed], cookies: [youTubeCookie])
        XCTAssertEqual(links[0], VideoLink(href: "videos/001-Talk.mp4", posterFile: "images/video-001-Talk.webp",
                                           title: "Talk", outcome: .saved))
        let arguments = try String(contentsOf: record.appendingPathComponent("arguments"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        let videos = capture.appendingPathComponent("videos").path
        // The work folder is a fresh one in the temporary root.
        let tempArgument = try XCTUnwrap(arguments.first { $0.hasPrefix("temp:") })
        let work = String(tempArgument.dropFirst("temp:".count).dropLast("/temp".count))
        XCTAssertTrue(work.hasPrefix(temporaryRoot.path + "/"), work)
        XCTAssertEqual(arguments, tools.ytDlpBaseArguments + [
            "--no-playlist", "--no-progress", "--referer", page,
            "-f", "bv*+ba/b", "--merge-output-format", "mp4", "--remux-video", "mp4",
            "-P", "home:\(videos)", "-P", "temp:\(work)/temp", "-o", "001-Talk.%(ext)s",
            "--print", "after_move:filepath", "--no-simulate",
            "--write-thumbnail", "-P", "thumbnail:\(work)/thumbnail", "-o", "thumbnail:thumbnail.%(ext)s",
            "--cookies", "\(work)/cookies.txt", "--", embed.url,
        ])
        XCTAssertFalse(FileManager.default.fileExists(atPath: work))
        try assertNothingTemporaryLeft()
    }

    /// The browser's cookies never land in the export folder: yt-dlp gets a private file, with the
    /// embed's site's cookies only, that is gone once it has run.
    func testYtDlpGetsOnlyTheEmbedSitesCookiesInAPrivateFile() async throws {
        let record = try installYtDlpStub()
        let embed = CapturedVideo(index: 0, kind: .youtube, url: "https://www.youtube-nocookie.com/embed/abc123",
                                  pageURL: page, frameOrigin: "https://www.youtube-nocookie.com", title: "Talk")
        let cookies = [
            youTubeCookie,
            HTTPCookie(properties: [.domain: ".google.com", .path: "/", .name: "SID", .value: "g", .secure: "TRUE"])!,
            HTTPCookie(properties: [.domain: "accounts.google.com", .path: "/", .name: "LSID", .value: "l"])!,
            sessionCookie,
            HTTPCookie(properties: [.domain: ".notyoutube.com", .path: "/", .name: "evil", .value: "e"])!,
            HTTPCookie(properties: [.domain: "bank.example", .path: "/", .name: "bank", .value: "b"])!,
        ]

        let links = await download([embed], cookies: cookies)
        XCTAssertEqual(links[0]?.outcome, .saved)
        let modes = try String(contentsOf: record.appendingPathComponent("modes"), encoding: .utf8)
        XCTAssertEqual(modes, "600 700\n")
        let file = try String(contentsOf: record.appendingPathComponent("cookies"), encoding: .utf8)
        let names = file.split(separator: "\n").filter { !$0.hasPrefix("# ") }.map { $0.split(separator: "\t")[5] }
        XCTAssertEqual(names.sorted(), ["LSID", "PREF", "SID"])
        let path = try String(contentsOf: record.appendingPathComponent("cookies-path"), encoding: .utf8)
            .trimmingCharacters(in: .newlines)
        XCTAssertTrue(path.hasPrefix(temporaryRoot.path + "/"), path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        try assertNothingTemporaryLeft()
    }

    func testYtDlpCookiesAreThoseOfTheEmbedsSite() {
        let cookie = { (domain: String) in HTTPCookie(properties: [.domain: domain, .path: "/", .name: domain, .value: "v"])! }
        let all = ["vimeo.com", ".player.vimeo.com", ".vimeocdn.com", ".youtube.com", ".google.com", "other.test"].map(cookie)
        let names = { (url: String) in VideoDownloader.ytDlpCookies(all, for: url).map(\.name) }
        XCTAssertEqual(names("https://player.vimeo.com/video/1"), ["vimeo.com", ".player.vimeo.com", ".vimeocdn.com"])
        XCTAssertEqual(names("https://www.youtube.com/embed/x"), [".youtube.com", ".google.com"])
        XCTAssertEqual(names("https://other.test/embed/x"), ["other.test"])
        XCTAssertEqual(names("not a url"), [])
    }

    func testTimeLimitStopsYtDlpAndWhatItStarted() async throws {
        let record = try installYtDlpStub(body: """
            echo $$ > "$record/tool.pid"
            sleep 60 &
            echo $! > "$record/child.pid"
            wait
            """)
        let embed = CapturedVideo(index: 0, kind: .vimeo, url: "https://player.vimeo.com/video/1", pageURL: page,
                                  frameOrigin: "https://player.vimeo.com")
        // Checking the working copy against the bundled yt-dlp takes longer than the limit.
        _ = try await tools.executableURL(for: .ytDlp)

        let started = ContinuousClock.now
        let links = await download([embed], timeLimit: .seconds(1))
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
        guard case .failed(let message)? = links[0]?.outcome else { return XCTFail("\(links)") }
        XCTAssertTrue(message.hasPrefix("Timed out"), message)
        for name in ["tool.pid", "child.pid"] {
            let pid = try XCTUnwrap(pid_t(String(contentsOf: record.appendingPathComponent(name), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)), name)
            let deadline = ContinuousClock.now + .seconds(2)
            while kill(pid, 0) == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
            XCTAssertNotEqual(kill(pid, 0), 0, "\(name) \(pid) still runs")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: capture.appendingPathComponent("videos").path))
        try assertNothingTemporaryLeft()
    }

    func testPrivateDirectoryRefusesAnExistingOneOthersCanEnter() throws {
        let open = folder.appendingPathComponent("open")
        try FileManager.default.createDirectory(at: open, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o755])
        XCTAssertThrowsError(try VideoDownloader.makePrivateDirectory(open))
        let made = folder.appendingPathComponent("private")
        try VideoDownloader.makePrivateDirectory(made)
        try VideoDownloader.makePrivateDirectory(made)
        let mode = try FileManager.default.attributesOfItem(atPath: made.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o700)
    }

    private var youTubeCookie: HTTPCookie {
        HTTPCookie(properties: [.domain: ".youtube.com", .path: "/", .name: "PREF", .value: "f6=8"])!
    }

    /// Installs a stand-in yt-dlp working copy and returns the folder it records into: its
    /// arguments, and the cookies file it was given (path, content, and the modes of the file and
    /// its folder). Unless `body` replaces it, it then writes the files the real one would.
    private func installYtDlpStub(body: String? = nil) throws -> URL {
        let record = folder.appendingPathComponent("record", isDirectory: true)
        try FileManager.default.createDirectory(at: record, withIntermediateDirectories: true)
        let copy = tools.ytDlpWorkingCopy
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        let action = body ?? """
            out="$home/${template%.%(ext)s}.mp4"
            cp '\(video.appendingPathComponent("video-only.mp4").path)' "$out"
            [ -n "$thumbs" ] && mkdir -p "$thumbs" && printf 'webp' > "$thumbs/thumbnail.webp"
            echo "$out"
            """
        try """
            #!/bin/bash
            if [ "$1" = "--version" ]; then echo 2099.01.01; exit 0; fi
            record='\(record.path)'
            printf '%s\\n' "$@" > "$record/arguments"
            while [ $# -gt 0 ]; do
                case "$1" in
                    -P) case "$2" in home:*) home="${2#home:}";; thumbnail:*) thumbs="${2#thumbnail:}";; esac; shift 2;;
                    -o) case "$2" in thumbnail:*) ;; *) template="$2";; esac; shift 2;;
                    --cookies) cookies="$2"; shift 2;;
                    *) shift;;
                esac
            done
            if [ -n "$cookies" ]; then
                echo "$cookies" > "$record/cookies-path"
                cp "$cookies" "$record/cookies"
                echo "$(stat -f %Lp "$cookies") $(stat -f %Lp "$(dirname "$cookies")")" > "$record/modes"
            fi
            \(action)
            """.write(to: copy, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copy.path)
        return record
    }

    // MARK: - Helpers

    private func streamCodecs(_ file: URL) async throws -> [String] {
        let result = try await tools.run(.ffprobe, arguments: [
            "-v", "error", "-show_entries", "stream=codec_name", "-of", "default=nw=1:nk=1", file.path,
        ])
        XCTAssertTrue(result.succeeded, result.stderr)
        return result.stdout.split(whereSeparator: \.isNewline).map(String.init)
    }
}

/// A minimal HTTP/1.1 server on 127.0.0.1 serving fixed responses, one request per connection.
final class FixtureHTTPServer: @unchecked Sendable {
    struct Request { var path: String; var headers: [String: String] }
    private struct Route { var body: Data; var contentType: String; var requiresCookie: String? }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "FixtureHTTPServer")
    private let lock = NSLock()
    private var routes = [String: Route]()
    private var recorded = [Request]()
    private(set) var port: UInt16 = 0

    private init() throws {
        listener = try NWListener(using: .tcp, on: .any)
    }

    static func start() async throws -> FixtureHTTPServer {
        let server = try FixtureHTTPServer()
        server.listener.newConnectionHandler = { [server] in server.handle($0) }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            server.listener.stateUpdateHandler = { [server] state in
                switch state {
                case .ready:
                    server.listener.stateUpdateHandler = nil
                    continuation.resume(returning: server.listener.port?.rawValue ?? 0)
                case .failed(let error):
                    server.listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            server.listener.start(queue: server.queue)
        }
        server.port = port
        return server
    }

    func stop() { listener.cancel() }

    func url(_ path: String) -> String { "http://127.0.0.1:\(port)\(path)" }

    var requests: [Request] { lock.withLock { recorded } }

    func route(_ path: String, _ body: Data, contentType: String = "application/octet-stream", requiresCookie: String? = nil) {
        lock.withLock { routes[path] = Route(body: body, contentType: contentType, requiresCookie: requiresCookie) }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, done, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                respond(to: String(decoding: buffer[..<end.lowerBound], as: UTF8.self), on: connection)
            } else if done || error != nil {
                connection.cancel()
            } else {
                receive(connection, buffer: buffer)
            }
        }
    }

    private func respond(to head: String, on connection: NWConnection) {
        let lines = head.components(separatedBy: "\r\n")
        let target = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        let path = String(target.split(separator: "?", maxSplits: 1).first ?? "/")
        var headers = [String: String]()
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let route: Route? = lock.withLock {
            recorded.append(Request(path: path, headers: headers))
            return routes[path]
        }
        var status = "200 OK", body = Data(), type = "text/plain"
        if let route {
            if let cookie = route.requiresCookie, !(headers["cookie"] ?? "").contains(cookie) {
                status = "403 Forbidden"
            } else {
                body = route.body
                type = route.contentType
            }
        } else {
            status = "404 Not Found"
        }
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }
}

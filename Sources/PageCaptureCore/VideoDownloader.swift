import Foundation

/// Saves a capture's videos into `videos/` (SPEC "Videos") and says how each appears in the outputs.
///
/// Direct files and HLS streams are fetched with the browser's cookies and the video's frame as
/// Referer; HLS segments are joined by the bundled ffmpeg without re-encoding. YouTube and Vimeo
/// embeds go through the bundled yt-dlp. DRM-protected videos are never downloaded. Videos are
/// processed one at a time, each within a time limit; one failure never stops the others.
public enum VideoDownloader {
    /// The longest one video may take before it is given up.
    public static let defaultTimeLimit: Duration = .seconds(20 * 60)
    /// HLS segments downloaded at once.
    static let maxConcurrentSegments = 4

    /// Downloads `videos` into `folder/videos/` as `001-<name>.<ext>`, … (numbered by `index`).
    /// - Parameters:
    ///   - posters: video index → file name inside `images/` of its already-downloaded poster.
    ///     Saved videos without one get the site thumbnail (yt-dlp) or a frame taken by ffmpeg.
    ///   - cookies: typically all of the web view's `httpCookieStore`. Each request gets the ones
    ///     that match its URL; yt-dlp gets the ones of the embed's site (`ytDlpCookies`).
    ///   - sessionConfiguration: base session configuration; defaults to ephemeral.
    ///   - temporaryRoot: where the work folders go (segments, yt-dlp's parts and cookies file);
    ///     nothing temporary is written into `folder`.
    /// - Returns: one link per video index. Cancelling the task kills the running tool; the videos
    ///   not saved by then are `failed("Cancelled")`.
    public static func download(
        _ videos: [CapturedVideo],
        into folder: URL,
        posters: [Int: String],
        cookies: [HTTPCookie],
        sessionConfiguration: URLSessionConfiguration = .ephemeral,
        tools: Tools,
        timeLimit: Duration = defaultTimeLimit,
        temporaryRoot: URL = defaultTemporaryRoot
    ) async -> [Int: VideoLink] {
        guard !videos.isEmpty else { return [:] }
        let config = sessionConfiguration.copy() as! URLSessionConfiguration
        // As in ImageDownloader: a private jar does the cookie matching, the header is set by hand.
        let jar = URLSessionConfiguration.ephemeral.httpCookieStorage ?? HTTPCookieStorage()
        for cookie in cookies { jar.setCookie(cookie) }
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = Double(timeLimit.components.seconds)
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let job = Job(
            folder: folder, posters: posters, cookies: cookies, jar: jar, session: session, tools: tools,
            timeLimit: timeLimit, temporaryRoot: temporaryRoot,
            workRoot: temporaryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true))
        var links = [Int: VideoLink]()
        for video in videos {
            links[video.index] = await job.process(video)
        }
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: job.workRoot)
        if (try? fileManager.contentsOfDirectory(atPath: job.videosFolder.path))?.isEmpty == true {
            try? fileManager.removeItem(at: job.videosFolder)
        }
        return links
    }

    /// `$TMPDIR/PageCapture`, private to the user like `$TMPDIR` itself.
    public static var defaultTemporaryRoot: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("PageCapture", isDirectory: true)
    }

    /// Removes what downloads left in `root`: everything, when no export runs (at launch and quit).
    public static func removeTemporaryFiles(in root: URL = defaultTemporaryRoot) {
        try? FileManager.default.removeItem(at: root)
    }

    /// Creates `url` with mode 0700. An existing directory is accepted only if it is this user's
    /// and nobody else can enter it.
    static func makePrivateDirectory(_ url: URL) throws {
        if mkdir(url.path, 0o700) == 0 { return }
        let error = errno
        var info = stat()
        guard error == EEXIST, lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: error == EEXIST ? EACCES : error) ?? .EIO)
        }
    }

    /// Writes `text` to a new file created with mode 0600 (it must not exist yet).
    static func writePrivateFile(_ text: String, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    /// The sites whose cookies a YouTube or Vimeo embed may need (sign-in lives on google.com).
    static let cookieSites: [[String]] = [
        ["youtube.com", "youtube-nocookie.com", "google.com"],
        ["vimeo.com", "vimeocdn.com"],
    ]

    /// The cookies yt-dlp gets for `videoURL`: those of the sites in its host's `cookieSites`
    /// entry (or of its host alone), never the rest of the browser's.
    static func ytDlpCookies(_ cookies: [HTTPCookie], for videoURL: String) -> [HTTPCookie] {
        guard let host = URL(string: videoURL)?.host?.lowercased(), !host.isEmpty else { return [] }
        let within = { (name: String, site: String) in name == site || name.hasSuffix("." + site) }
        let sites = cookieSites.first { $0.contains { within(host, $0) } } ?? [host]
        return cookies.filter { cookie in
            var domain = cookie.domain.lowercased()
            if domain.hasPrefix(".") { domain.removeFirst() }
            return sites.contains { within(domain, $0) }
        }
    }

    /// The cookies in the Netscape format yt-dlp reads with `--cookies`, or nil if there are none.
    static func netscapeCookieFile(_ cookies: [HTTPCookie]) -> String? {
        guard !cookies.isEmpty else { return nil }
        var lines = ["# Netscape HTTP Cookie File"]
        for cookie in cookies {
            let domain = cookie.domain
            let expiry = cookie.expiresDate.map { Int($0.timeIntervalSince1970) } ?? 0
            lines.append([
                (cookie.isHTTPOnly ? "#HttpOnly_" : "") + domain,
                domain.hasPrefix(".") ? "TRUE" : "FALSE",
                cookie.path,
                cookie.isSecure ? "TRUE" : "FALSE",
                String(expiry),
                cookie.name,
                cookie.value,
            ].joined(separator: "\t"))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Why a video was not saved.
enum VideoError: Error, Equatable {
    case protected
    case failed(String)
}

/// A saved video file in `videos/`, and the site thumbnail yt-dlp wrote, if asked for one.
private struct SavedVideo: Sendable {
    var fileName: String
    var thumbnail: URL?
}

/// What every video of one download shares.
private struct Job: Sendable {
    let folder: URL
    let posters: [Int: String]
    let cookies: [HTTPCookie]
    /// All of `cookies`, for matching each request's URL.
    let jar: HTTPCookieStorage
    let session: URLSession
    let tools: Tools
    let timeLimit: Duration
    let temporaryRoot: URL
    /// This download's private folder in `temporaryRoot`; a work folder per video goes inside.
    let workRoot: URL

    var videosFolder: URL { folder.appendingPathComponent(ExportNaming.videosFolder, isDirectory: true) }
    var imagesFolder: URL { folder.appendingPathComponent(ExportNaming.imagesFolder, isDirectory: true) }

    func process(_ video: CapturedVideo) async -> VideoLink {
        let title = video.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var link = VideoLink(
            href: video.url,
            posterFile: posters[video.index].map(ExportNaming.relativeImagePath),
            title: title.isEmpty ? "Video \(video.index + 1)" : title,
            outcome: .failed("Cancelled"))
        switch video.kind {
        case .drm:
            link.outcome = .protected
            return link
        case .unknown:
            link.href = video.pageURL
            link.outcome = .failed("No video source was found")
            return link
        case .dash:
            // The bundled ffmpeg has no DASH demuxer.
            link.outcome = .failed("DASH streams are not supported")
            return link
        case .file, .hls, .youtube, .vimeo:
            break
        }
        if Task.isCancelled { return link }

        let stem = ExportNaming.videoFileStem(index: video.index, title: video.title, url: video.url)
        let work = workRoot.appendingPathComponent(String(format: "%03d", video.index + 1), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let wantsThumbnail = link.posterFile == nil
        do {
            try VideoDownloader.makePrivateDirectory(temporaryRoot)
            try VideoDownloader.makePrivateDirectory(workRoot)
            try VideoDownloader.makePrivateDirectory(work)
            try FileManager.default.createDirectory(at: videosFolder, withIntermediateDirectories: true)
            let poster = try await withTimeLimit {
                let saved: SavedVideo
                switch video.kind {
                case .file: saved = try await downloadFile(video, stem: stem, work: work)
                case .hls: saved = try await downloadHLS(video, stem: stem, work: work)
                default: saved = try await runYtDlp(video, stem: stem, work: work, writeThumbnail: wantsThumbnail)
                }
                let poster = wantsThumbnail ? await makePoster(for: saved, stem: stem) : nil
                return (saved.fileName, poster)
            }
            link.href = ExportNaming.relativeVideoPath(poster.0)
            if let posterFile = poster.1 { link.posterFile = ExportNaming.relativeImagePath(posterFile) }
            link.outcome = .saved
        } catch VideoError.protected {
            link.outcome = .protected
        } catch let VideoError.failed(message) {
            link.outcome = .failed(message)
        } catch let ToolError.missing(url) {
            link.outcome = .failed("\(url.lastPathComponent) is missing")
        } catch is CancellationError {
            link.outcome = .failed("Cancelled")
        } catch let error as URLError where error.code == .cancelled {
            link.outcome = .failed("Cancelled")
        } catch {
            link.outcome = .failed(error.localizedDescription)
        }
        return link
    }

    /// Runs `operation`, cancelling it (which kills its tools) when the time limit passes first.
    private func withTimeLimit<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let limit = timeLimit
        return try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: limit)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let value = first else {
                throw VideoError.failed("Timed out after \(limit.components.seconds / 60) minutes")
            }
            return value
        }
    }

    // MARK: - Direct files

    private func downloadFile(_ video: CapturedVideo, stem: String, work: URL) async throws -> SavedVideo {
        let url = try httpURL(video.url)
        let (file, response) = try await fetch(url, referer: video.pageURL, into: work.appendingPathComponent("download"))
        let fileName = "\(stem).\(Self.fileExtension(for: url, mimeType: response.mimeType))"
        try moveReplacing(file, to: videosFolder.appendingPathComponent(fileName))
        return SavedVideo(fileName: fileName)
    }

    private static let videoFileExtensions: Set<String> = ["mp4", "m4v", "mov", "webm", "mkv", "ogv", "ogg", "avi", "3gp"]

    static func fileExtension(for url: URL, mimeType: String?) -> String {
        let ext = url.pathExtension.lowercased()
        if videoFileExtensions.contains(ext) { return ext }
        switch mimeType?.lowercased() {
        case "video/webm": return "webm"
        case "video/quicktime": return "mov"
        case "video/x-matroska": return "mkv"
        case "video/ogg": return "ogv"
        default: return "mp4"
        }
    }

    // MARK: - HLS

    private func downloadHLS(_ video: CapturedVideo, stem: String, work: URL) async throws -> SavedVideo {
        let url = try httpURL(video.url)
        let first = try HLSPlaylist(try await fetchText(url, referer: video.pageURL), url: url)
        try first.checkEncryption()
        var media = [first]
        if first.isMaster {
            guard let variant = first.bestVariant() else { throw VideoError.failed("The HLS stream has no variants") }
            media = [try HLSPlaylist(try await fetchText(variant.url, referer: video.pageURL), url: variant.url)]
            if let audio = first.audioRendition(for: variant) {
                media.append(try HLSPlaylist(try await fetchText(audio, referer: video.pageURL), url: audio))
            }
        }
        // Everything is checked before the first segment is fetched.
        for playlist in media {
            try playlist.checkEncryption()
            guard !playlist.isMaster else { throw VideoError.failed("Nested HLS master playlists are not supported") }
            guard playlist.isComplete else { throw VideoError.failed("Live streams cannot be saved") }
        }

        var names = [String: String]()
        var downloads = [(URL, String)]()
        var playlists = [URL]()
        for (number, playlist) in media.enumerated() {
            let prefix = number == 0 ? "v" : "a"
            let text = try playlist.localCopy(prefix: prefix, names: &names, downloads: &downloads)
            let file = work.appendingPathComponent("\(prefix).m3u8")
            try Data(text.utf8).write(to: file)
            playlists.append(file)
        }
        try await downloadAll(downloads, referer: video.pageURL, into: work)

        // The playlists are the app's own, so any local file name is allowed.
        let input = ["-allowed_extensions", "ALL", "-extension_picky", "0"]
        let output = work.appendingPathComponent("joined.mp4")
        var arguments = ["-nostdin", "-v", "error", "-y"]
        for playlist in playlists { arguments += input + ["-i", playlist.path] }
        if playlists.count > 1 {
            arguments += ["-map", "0:v:0", "-map", "1:a:0"]
        } else {
            arguments += ["-sn", "-dn"]
        }
        let audioCodec = try await firstAudioCodec(of: playlists.last!, inputOptions: input)
        if audioCodec == "aac" { arguments += ["-bsf:a", "aac_adtstoasc"] }
        arguments += ["-c", "copy", output.path]
        let result = try await tools.run(.ffmpeg, arguments: arguments)
        guard result.succeeded, FileManager.default.fileExists(atPath: output.path) else {
            throw VideoError.failed("ffmpeg could not join the stream: \(Self.lastLine(of: result.stderr))")
        }
        let fileName = "\(stem).mp4"
        try moveReplacing(output, to: videosFolder.appendingPathComponent(fileName))
        return SavedVideo(fileName: fileName)
    }

    private func firstAudioCodec(of file: URL, inputOptions: [String]) async throws -> String? {
        let result = try await tools.run(.ffprobe, arguments: ["-v", "error"] + inputOptions + [
            "-select_streams", "a:0", "-show_entries", "stream=codec_name", "-of", "default=nw=1:nk=1", file.path,
        ])
        guard result.succeeded else { return nil }
        return result.stdout.split(whereSeparator: \.isNewline).first.map(String.init)
    }

    /// Downloads `items` (remote URL, local file name) into `folder`, a few at a time.
    private func downloadAll(_ items: [(URL, String)], referer: String, into folder: URL) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            func addNext() {
                guard next < items.count else { return }
                let (url, name) = items[next]
                next += 1
                group.addTask {
                    let (file, _) = try await fetch(url, referer: referer, into: folder.appendingPathComponent(name + ".part"))
                    try moveReplacing(file, to: folder.appendingPathComponent(name))
                }
            }
            for _ in 0..<VideoDownloader.maxConcurrentSegments { addNext() }
            while try await group.next() != nil { addNext() }
        }
    }

    // MARK: - yt-dlp

    private func runYtDlp(_ video: CapturedVideo, stem: String, work: URL, writeThumbnail: Bool) async throws -> SavedVideo {
        let thumbnails = work.appendingPathComponent("thumbnail", isDirectory: true)
        var arguments = [
            "--no-playlist", "--no-progress",
            "--referer", video.pageURL,
            "-f", "bv*+ba/b", "--merge-output-format", "mp4", "--remux-video", "mp4",
            "-P", "home:\(videosFolder.path)", "-P", "temp:\(work.appendingPathComponent("temp").path)",
            "-o", "\(stem).%(ext)s",
            // The final path, once yt-dlp has merged and moved the file.
            "--print", "after_move:filepath", "--no-simulate",
        ]
        if writeThumbnail {
            // The bundled ffmpeg cannot decode JPEG or WebP, so the thumbnail keeps its own format.
            arguments += ["--write-thumbnail", "-P", "thumbnail:\(thumbnails.path)", "-o", "thumbnail:thumbnail.%(ext)s"]
        }
        // yt-dlp also writes the cookies back to the file when it ends.
        let cookieFile = work.appendingPathComponent("cookies.txt")
        defer { try? FileManager.default.removeItem(at: cookieFile) }
        if let cookies = VideoDownloader.netscapeCookieFile(VideoDownloader.ytDlpCookies(self.cookies, for: video.url)) {
            try VideoDownloader.writePrivateFile(cookies, to: cookieFile)
            arguments += ["--cookies", cookieFile.path]
        }
        arguments += ["--", video.url]

        let result = try await tools.run(.ytDlp, arguments: arguments)
        guard result.succeeded else {
            let errors = result.stderr.split(whereSeparator: \.isNewline).filter { $0.hasPrefix("ERROR:") }
            throw VideoError.failed(errors.last.map { String($0.prefix(300)) } ?? "yt-dlp failed: \(Self.lastLine(of: result.stderr))")
        }
        let printed = result.stdout.split(whereSeparator: \.isNewline).map(String.init).last { !$0.isEmpty }
        guard let printed, FileManager.default.fileExists(atPath: printed) else {
            throw VideoError.failed("yt-dlp did not save a file")
        }
        let produced = URL(fileURLWithPath: printed)
        var fileName = produced.lastPathComponent
        if produced.deletingLastPathComponent().standardizedFileURL.path != videosFolder.standardizedFileURL.path {
            fileName = "\(stem).\(produced.pathExtension.isEmpty ? "mp4" : produced.pathExtension)"
            try moveReplacing(produced, to: videosFolder.appendingPathComponent(fileName))
        }
        let thumbnail = (try? FileManager.default.contentsOfDirectory(at: thumbnails, includingPropertiesForKeys: nil))?
            .first { !$0.lastPathComponent.hasPrefix(".") }
        return SavedVideo(fileName: fileName, thumbnail: thumbnail)
    }

    // MARK: - Poster

    /// Puts a preview image for a saved video into `images/` and returns its file name: the site
    /// thumbnail if there is one, else a frame at 1 s (0 s for videos under 2 s). Nil if neither works.
    private func makePoster(for saved: SavedVideo, stem: String) async -> String? {
        try? FileManager.default.createDirectory(at: imagesFolder, withIntermediateDirectories: true)
        if let thumbnail = saved.thumbnail {
            var ext = thumbnail.pathExtension.isEmpty ? "jpg" : thumbnail.pathExtension.lowercased()
            // Thumbnails are often WebP; save those as PNG so every viewer shows them.
            if let data = try? Data(contentsOf: thumbnail), let png = PortableImage.pngData(from: data),
               (try? png.write(to: thumbnail, options: .atomic)) != nil {
                ext = "png"
            }
            let fileName = "video-\(stem).\(ext)"
            if (try? moveReplacing(thumbnail, to: imagesFolder.appendingPathComponent(fileName))) != nil { return fileName }
        }
        let video = videosFolder.appendingPathComponent(saved.fileName)
        let fileName = "video-\(stem).png"
        let output = imagesFolder.appendingPathComponent(fileName)
        guard let probe = try? await tools.run(.ffprobe, arguments: [
            "-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", video.path,
        ]) else { return nil }
        let duration = Double(probe.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        guard let result = try? await tools.run(.ffmpeg, arguments: [
            "-nostdin", "-v", "error", "-y", "-ss", duration >= 2 ? "1" : "0", "-i", video.path,
            "-frames:v", "1", "-vf", "scale=w='min(1280,iw)':h=-2", output.path,
        ]), result.succeeded else { return nil }
        // ffmpeg exits successfully without writing anything when there is no frame to take.
        let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
        return size > 0 ? fileName : nil
    }

    // MARK: - HTTP

    private func httpURL(_ string: String) throws -> URL {
        guard let url = URL(string: string), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw VideoError.failed("Unsupported address")
        }
        return url
    }

    private func request(_ url: URL, referer: String) -> URLRequest {
        var request = URLRequest(url: url)
        if !referer.isEmpty { request.setValue(referer, forHTTPHeaderField: "Referer") }
        request.httpShouldHandleCookies = false
        for (field, value) in HTTPCookie.requestHeaderFields(with: jar.cookies(for: url) ?? []) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return request
    }

    /// Streams `url` to disk at `destination`.
    private func fetch(_ url: URL, referer: String, into destination: URL) async throws -> (URL, URLResponse) {
        let (file, response) = try await session.download(for: request(url, referer: referer))
        try moveReplacing(file, to: destination)
        try check(response, for: url, file: destination)
        return (destination, response)
    }

    private func fetchText(_ url: URL, referer: String) async throws -> String {
        let (data, response) = try await session.data(for: request(url, referer: referer))
        try check(response, for: url, file: nil)
        return String(decoding: data, as: UTF8.self)
    }

    private func check(_ response: URLResponse, for url: URL, file: URL?) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if let file { try? FileManager.default.removeItem(at: file) }
            throw VideoError.failed("HTTP \(http.statusCode) for \(url.lastPathComponent)")
        }
        // A sign-in or error page instead of the media.
        if file != nil, response.mimeType?.lowercased().hasPrefix("text/html") == true {
            try? FileManager.default.removeItem(at: file!)
            throw VideoError.failed("Got a web page instead of \(url.lastPathComponent)")
        }
    }

    private func moveReplacing(_ source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.moveItem(at: source, to: destination)
    }

    private static func lastLine(of text: String) -> String {
        String(text.split(whereSeparator: \.isNewline).last?.prefix(300) ?? "no output")
    }
}

// MARK: - HLS playlists

/// An HLS playlist (RFC 8216), as far as saving it needs.
struct HLSPlaylist {
    struct Variant: Equatable {
        var url: URL
        var bandwidth: Int
        var audioGroup: String?
    }

    let url: URL
    let lines: [String]

    init(_ text: String, url: URL) throws {
        self.url = url
        lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.first?.hasPrefix("#EXTM3U") == true else { throw VideoError.failed("Not an HLS playlist") }
    }

    var isMaster: Bool { lines.contains { $0.hasPrefix("#EXT-X-STREAM-INF:") } }
    /// A media playlist that will not grow (VOD, or a finished event).
    var isComplete: Bool { lines.contains("#EXT-X-ENDLIST") }

    /// Throws `protected` for DRM (SAMPLE-AES, or a key format other than clear-key "identity"),
    /// and `failed` for encryption it does not know. Clear-key AES-128 passes.
    func checkEncryption() throws {
        for line in lines where line.hasPrefix("#EXT-X-KEY:") || line.hasPrefix("#EXT-X-SESSION-KEY:") {
            let attributes = Self.attributes(of: line)
            let method = (attributes["METHOD"] ?? "NONE").uppercased()
            if method == "NONE" { continue }
            if method == "SAMPLE-AES" || method == "SAMPLE-AES-CTR" { throw VideoError.protected }
            if let format = attributes["KEYFORMAT"], format.lowercased() != "identity" { throw VideoError.protected }
            if method != "AES-128" { throw VideoError.failed("Unsupported HLS encryption \(method)") }
        }
    }

    /// The variant with the highest BANDWIDTH (the first of equals).
    func bestVariant() -> Variant? {
        var best: Variant?
        var pending: [String: String]?
        for line in lines {
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pending = Self.attributes(of: line)
            } else if let attributes = pending, !line.isEmpty, !line.hasPrefix("#") {
                pending = nil
                guard let url = URL(string: line, relativeTo: url)?.absoluteURL else { continue }
                let variant = Variant(url: url, bandwidth: Int(attributes["BANDWIDTH"] ?? "") ?? 0,
                                      audioGroup: attributes["AUDIO"])
                if variant.bandwidth > best?.bandwidth ?? -1 { best = variant }
            }
        }
        return best
    }

    /// The playlist of the audio rendition `variant` names (DEFAULT=YES preferred), or nil when its
    /// audio is in the variant itself.
    func audioRendition(for variant: Variant) -> URL? {
        guard let group = variant.audioGroup else { return nil }
        let renditions = lines.filter { $0.hasPrefix("#EXT-X-MEDIA:") }.map(Self.attributes(of:))
            .filter { $0["TYPE"] == "AUDIO" && $0["GROUP-ID"] == group }
        let chosen = renditions.first { $0["DEFAULT"] == "YES" } ?? renditions.first
        return chosen?["URI"].flatMap { URL(string: $0, relativeTo: url)?.absoluteURL }
    }

    /// This media playlist pointing at local files named `<prefix>00001.<ext>`, …, which it adds to
    /// `downloads`. `names` (remote URL → local name) is shared between playlists, so a resource
    /// they share (typically the key) is fetched once.
    func localCopy(prefix: String, names: inout [String: String], downloads: inout [(URL, String)]) throws -> String {
        let hasInitSegment = lines.contains { $0.hasPrefix("#EXT-X-MAP:") }
        func local(_ uri: String, defaultExtension: String, keepExtension: Bool = true) throws -> String {
            guard let remote = URL(string: uri, relativeTo: url)?.absoluteURL,
                  ["http", "https"].contains(remote.scheme?.lowercased() ?? "") else {
                throw VideoError.failed("Unsupported HLS address \(uri)")
            }
            if let name = names[remote.absoluteString] { return name }
            let ext = remote.pathExtension.lowercased()
            let name = String(format: "\(prefix)%05d.", downloads.count + 1)
                + (keepExtension && Self.mediaExtensions.contains(ext) ? ext : defaultExtension)
            names[remote.absoluteString] = name
            downloads.append((remote, name))
            return name
        }
        var out = [String]()
        for line in lines {
            if line.hasPrefix("#EXT-X-KEY:") || line.hasPrefix("#EXT-X-MAP:"), let uri = Self.attributes(of: line)["URI"] {
                let isKey = line.hasPrefix("#EXT-X-KEY:")
                let name = try local(uri, defaultExtension: isKey ? "key" : "mp4", keepExtension: !isKey)
                out.append(line.replacingOccurrences(of: "URI=\"\(uri)\"", with: "URI=\"\(name)\""))
            } else if !line.isEmpty, !line.hasPrefix("#") {
                out.append(try local(line, defaultExtension: hasInitSegment ? "m4s" : "ts"))
            } else {
                out.append(line)
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    private static let mediaExtensions: Set<String> = [
        "ts", "m4s", "mp4", "m4a", "m4v", "aac", "mp3", "ac3", "ec3", "eac3", "cmfv", "cmfa", "fmp4", "mov", "vtt", "webvtt",
    ]

    /// The attribute list of a tag line (`#TAG:A=1,B="x,y"`), quotes removed.
    static func attributes(of line: String) -> [String: String] {
        guard let colon = line.firstIndex(of: ":") else { return [:] }
        var result = [String: String]()
        var key = "", value = ""
        var inKey = true, inQuotes = false
        for character in line[line.index(after: colon)...] {
            if inKey {
                if character == "=" { inKey = false } else if character != "," { key.append(character) }
            } else if character == "\"" {
                inQuotes.toggle()
            } else if character == ",", !inQuotes {
                result[key.trimmingCharacters(in: .whitespaces)] = value
                key = ""; value = ""; inKey = true
            } else {
                value.append(character)
            }
        }
        if !key.isEmpty { result[key.trimmingCharacters(in: .whitespaces)] = value }
        return result
    }
}

import Foundation

/// A downloaded original, in a private work folder of its own until `discard()`.
public struct DownloadedDocument: Equatable, Sendable {
    /// `original.<ext>` (mode 0600) inside the work folder (mode 0700).
    public var file: URL
    public var source: DocumentSource
    /// The page that showed the document, if known.
    public var page: URL?

    /// Deletes the work folder (the exporter has copied what it needs).
    public func discard() {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }
}

/// Downloads a document's original with the browser's cookies and Referer for the page
/// (`BrowserRequest`, SPEC "Documents").
public enum DocumentDownloader {
    /// The largest original that is downloaded (the converter's input cap too).
    public static let maxBytes = 500 << 20
    private static let chunkSize = 1 << 16

    /// Streams `source` into a new private work folder under `temporaryRoot`, which launch and quit
    /// empty (`VideoDownloader.removeTemporaryFiles`).
    /// - Parameters:
    ///   - referer: the page that shows the document.
    ///   - cookies: typically all of the web view's `httpCookieStore`; each request (redirects
    ///     included) gets those a browser would send (`BrowserRequest`).
    ///   - configuration: base session configuration (tests add a `URLProtocol`).
    /// - Throws: `DocumentDownloadError` (`httpStatus`, `notADocument`, `tooLarge`, `failed`) or
    ///   `CancellationError`. Nothing is left behind when it throws.
    public static func download(
        _ source: DocumentSource,
        referer: URL?,
        cookies: [HTTPCookie],
        configuration: URLSessionConfiguration = .ephemeral,
        maxBytes: Int = DocumentDownloader.maxBytes,
        temporaryRoot: URL = VideoDownloader.defaultTemporaryRoot
    ) async throws -> DownloadedDocument {
        let config = configuration.copy() as! URLSessionConfiguration
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let browser = BrowserRequest(page: referer, cookies: cookies)

        let folder = temporaryRoot.appendingPathComponent("Document-\(UUID().uuidString)", isDirectory: true)
        let file = folder.appendingPathComponent("original.\(source.kind.fileExtension)")
        do {
            try await stream(browser.request(source.url), delegate: browser.redirects(), session: session,
                             kind: source.kind, maxBytes: maxBytes, folder: folder, to: file)
            return DownloadedDocument(file: file, source: source, page: referer)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            if error is DocumentDownloadError || error is CancellationError { throw error }
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw DocumentDownloadError.failed(error.localizedDescription)
        }
    }

    private static func stream(
        _ request: URLRequest, delegate: URLSessionTaskDelegate, session: URLSession, kind: DocumentKind,
        maxBytes: Int, folder: URL, to file: URL
    ) async throws {
        let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw DocumentDownloadError.httpStatus(http.statusCode)
        }
        if response.expectedContentLength > Int64(maxBytes) { throw DocumentDownloadError.tooLarge }

        try VideoDownloader.makePrivateDirectory(folder.deletingLastPathComponent())
        try VideoDownloader.makePrivateDirectory(folder)
        let descriptor = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }

        let magic = kind.magic
        var buffer = Data()
        buffer.reserveCapacity(chunkSize)
        var total = 0
        var checked = false
        for try await byte in bytes {
            buffer.append(byte)
            total += 1
            if total > maxBytes { throw DocumentDownloadError.tooLarge }
            // A sign-in or error page instead of the file.
            if !checked, total == magic.count {
                guard buffer.starts(with: magic) else { throw DocumentDownloadError.notADocument }
                checked = true
            }
            if buffer.count == chunkSize {
                try Task.checkCancellation()
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        guard checked else { throw DocumentDownloadError.notADocument }
        try handle.write(contentsOf: buffer)
    }
}

import Foundation

/// A downloaded original, in a work folder of its own until `discard()`.
public struct DownloadedDocument: Equatable, Sendable {
    /// `original.<ext>` inside the work folder.
    public var file: URL
    public var source: DocumentSource

    /// Deletes the work folder (the exporter has copied what it needs).
    public func discard() {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }
}

/// Downloads a document's original with the browser's cookies and the page as referer (SPEC "Documents").
public enum DocumentDownloader {
    /// The largest original that is downloaded (the converter's input cap too).
    public static let maxBytes = 500 << 20
    private static let chunkSize = 1 << 16

    /// Streams `source` into a new work folder under `temporaryRoot`.
    /// - Parameters:
    ///   - referer: the page that shows the document.
    ///   - cookies: typically all of the web view's `httpCookieStore`; the request gets those matching its URL.
    ///   - configuration: base session configuration (tests add a `URLProtocol`).
    /// - Throws: `DocumentDownloadError` (`httpStatus`, `notADocument`, `tooLarge`, `failed`) or
    ///   `CancellationError`. Nothing is left behind when it throws.
    public static func download(
        _ source: DocumentSource,
        referer: URL?,
        cookies: [HTTPCookie],
        configuration: URLSessionConfiguration = .ephemeral,
        maxBytes: Int = DocumentDownloader.maxBytes,
        temporaryRoot: URL = FileManager.default.temporaryDirectory
    ) async throws -> DownloadedDocument {
        let config = configuration.copy() as! URLSessionConfiguration
        // As in ImageDownloader: a private jar does the cookie matching, the header is set by hand.
        let jar = URLSessionConfiguration.ephemeral.httpCookieStorage ?? HTTPCookieStorage()
        for cookie in cookies { jar.setCookie(cookie) }
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: source.url)
        if let referer { request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer") }
        request.httpShouldHandleCookies = false
        for (field, value) in HTTPCookie.requestHeaderFields(with: jar.cookies(for: source.url) ?? []) {
            request.setValue(value, forHTTPHeaderField: field)
        }

        let folder = temporaryRoot.appendingPathComponent("PageCapture-Document-\(UUID().uuidString)", isDirectory: true)
        let file = folder.appendingPathComponent("original.\(source.kind.fileExtension)")
        do {
            try await stream(request, session: session, kind: source.kind, maxBytes: maxBytes, folder: folder, to: file)
            return DownloadedDocument(file: file, source: source)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            if error is DocumentDownloadError || error is CancellationError { throw error }
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw DocumentDownloadError.failed(error.localizedDescription)
        }
    }

    private static func stream(
        _ request: URLRequest, session: URLSession, kind: DocumentKind, maxBytes: Int, folder: URL, to file: URL
    ) async throws {
        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw DocumentDownloadError.httpStatus(http.statusCode)
        }
        if response.expectedContentLength > Int64(maxBytes) { throw DocumentDownloadError.tooLarge }

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: file)
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

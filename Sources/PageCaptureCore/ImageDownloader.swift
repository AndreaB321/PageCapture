import Foundation

/// The outcome of downloading a capture's images into `images/`.
public struct ImageDownloadResult: Equatable, Sendable {
    /// Remote image URL string (as in the page) → file name inside `images/`, for the images that downloaded.
    public var files: [String: String]
    /// Images that could not be downloaded, in capture order. Outputs keep their remote URLs.
    public var failed: [String]

    public init(files: [String: String] = [:], failed: [String] = []) {
        self.files = files
        self.failed = failed
    }

    /// Remote URL string → relative path (`images/<file>`), as the exporters take it.
    public var relativePaths: [String: String] {
        files.mapValues(ExportNaming.relativeImagePath)
    }
}

/// Downloads `<img>` sources with the browser's cookies and a Referer, so signed-in images work.
public enum ImageDownloader {
    private static let maxConcurrent = 6

    /// Downloads `urls` (the page's strings, which stay the result's keys) into `folder` as `001-<basename>.<ext>`, … (numbered by position in `urls`).
    /// `data:` URLs are decoded locally. A failed image is recorded, not thrown.
    /// - Parameters:
    ///   - cookies: copied into the session, typically from the web view's `httpCookieStore`.
    ///   - configuration: base session configuration (tests add a `URLProtocol`); defaults to ephemeral.
    public static func download(
        _ urls: [String],
        into folder: URL,
        referer: URL,
        cookies: [HTTPCookie],
        configuration: URLSessionConfiguration = .ephemeral
    ) async -> ImageDownloadResult {
        let config = configuration.copy() as! URLSessionConfiguration
        // A private jar that does the domain/path/secure matching; the Cookie header is set explicitly
        // per request so it does not depend on the session's own cookie handling.
        let jar = URLSessionConfiguration.ephemeral.httpCookieStorage ?? HTTPCookieStorage()
        for cookie in cookies { jar.setCookie(cookie) }
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        var result = ImageDownloadResult()
        var outcomes = [(Int, String?)]()
        await withTaskGroup(of: (Int, String?).self) { group in
            var next = 0
            func addNext() {
                guard next < urls.count else { return }
                let index = next
                next += 1
                group.addTask {
                    (index, await fetch(urls[index], index: index, into: folder, referer: referer, jar: jar, session: session))
                }
            }
            for _ in 0..<maxConcurrent { addNext() }
            for await outcome in group {
                outcomes.append(outcome)
                addNext()
            }
        }
        for (index, fileName) in outcomes.sorted(by: { $0.0 < $1.0 }) {
            if let fileName { result.files[urls[index]] = fileName } else { result.failed.append(urls[index]) }
        }
        return result
    }

    /// Returns the written file name, or `nil` on failure.
    private static func fetch(
        _ urlString: String, index: Int, into folder: URL, referer: URL, jar: HTTPCookieStorage, session: URLSession
    ) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        let data: Data
        let mimeType: String?
        if url.scheme?.lowercased() == "data" {
            guard let decoded = DataURL.decode(urlString) else { return nil }
            (data, mimeType) = decoded
        } else {
            var request = URLRequest(url: url)
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
            request.setValue("image/avif,image/webp,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
            request.httpShouldHandleCookies = false
            for (field, value) in HTTPCookie.requestHeaderFields(with: jar.cookies(for: url) ?? []) {
                request.setValue(value, forHTTPHeaderField: field)
            }
            guard let (body, response) = try? await session.data(for: request) else { return nil }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
            // A sign-in or error page instead of the image.
            if response.mimeType?.lowercased().hasPrefix("text/html") == true { return nil }
            guard !body.isEmpty else { return nil }
            data = body
            mimeType = response.mimeType
        }
        var fileName = ExportNaming.imageFileName(index: index, url: url, mimeType: mimeType)
        var bytes = data
        // AVIF, WebP, HEIC and JPEG XL are saved as PNG; an image that does not decode stays as downloaded.
        if let png = PortableImage.pngData(from: data) {
            bytes = png
            fileName = (fileName as NSString).deletingPathExtension + ".png"
        }
        do {
            try bytes.write(to: folder.appendingPathComponent(fileName), options: .atomic)
            return fileName
        } catch {
            return nil
        }
    }
}

import Foundation
import UniformTypeIdentifiers

/// Makes a capture's stylesheets self-contained for the HTML (SPEC "Saving"): linked sheets are
/// downloaded with the browser's cookies and the page as referer, `@import`s are inlined (to
/// `maxDepth` levels) and what their `url()`s reference (fonts, background images) is embedded as
/// `data:` URLs, up to `resourceLimit` bytes each and `totalLimit` in all; beyond that a `url()`
/// keeps its absolute URL. A sheet that fails to download is left out.
actor StylesheetInliner {
    static let maxDepth = 4
    private static let maxConcurrent = 6

    private let session: URLSession
    private let jar: HTTPCookieStorage
    private let referer: URL
    private let resourceLimit: Int
    private let totalLimit: Int
    /// Absolute URL → its `data:` URL, for the resources that were embedded.
    private var embedded = [URL: String]()
    private var tried = Set<URL>()
    private var total = 0

    /// The CSS text of each sheet that could be read, in order.
    static func inline(
        _ sheets: [CapturedContent.Stylesheet],
        page: URL,
        cookies: [HTTPCookie],
        configuration: URLSessionConfiguration,
        resourceLimit: Int = 5_000_000,
        totalLimit: Int = 50_000_000
    ) async -> [String] {
        let inliner = StylesheetInliner(page: page, cookies: cookies, configuration: configuration,
                                        resourceLimit: resourceLimit, totalLimit: totalLimit)
        defer { inliner.session.finishTasksAndInvalidate() }
        var out = [String]()
        for sheet in sheets {
            switch sheet {
            case .inline(let css):
                out.append(await inliner.expand(css, base: page, chain: []))
            case .link(let url):
                guard let css = await inliner.fetchText(url) else { continue }
                out.append(await inliner.expand(css, base: url, chain: [url]))
            }
        }
        return out
    }

    private init(page: URL, cookies: [HTTPCookie], configuration: URLSessionConfiguration,
                 resourceLimit: Int, totalLimit: Int) {
        let config = configuration.copy() as! URLSessionConfiguration
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        session = URLSession(configuration: config)
        // As in ImageDownloader: a private jar does the cookie matching, the header is set by hand.
        jar = URLSessionConfiguration.ephemeral.httpCookieStorage ?? HTTPCookieStorage()
        for cookie in cookies { jar.setCookie(cookie) }
        referer = page
        self.resourceLimit = resourceLimit
        self.totalLimit = totalLimit
    }

    /// `chain`: the sheets importing this one, which it must not import again.
    private func expand(_ css: String, base: URL, chain: [URL]) async -> String {
        let refs = CSSRewriter.references(in: css, base: base)
        var imported = [URL: String]()
        if chain.count <= Self.maxDepth {
            for url in refs.imports where !chain.contains(url) && imported[url] == nil {
                guard let text = await fetchText(url) else { continue }
                imported[url] = await expand(text, base: url, chain: chain + [url])
            }
        }
        await embed(refs.resources)
        return CSSRewriter.rewrite(css, base: base, imported: { imported[$0] },
                                   resource: { embedded[$0] ?? $0.absoluteString })
    }

    private func embed(_ urls: [URL]) async {
        let new = urls.filter { !tried.contains($0) }
        tried.formUnion(new)
        var fetched = [URL: (Data, String)]()
        let limit = resourceLimit
        await withTaskGroup(of: (URL, (Data, String)?).self) { group in
            var next = 0
            func addNext() {
                guard next < new.count else { return }
                let url = new[next]
                next += 1
                let request = self.request(url, accept: "*/*")
                let session = self.session
                group.addTask { (url, await Self.fetch(request, session: session, limit: limit)) }
            }
            for _ in 0..<Self.maxConcurrent { addNext() }
            for await (url, result) in group {
                fetched[url] = result
                addNext()
            }
        }
        for url in new {
            guard let (data, mime) = fetched[url], total + data.count <= totalLimit else { continue }
            total += data.count
            embedded[url] = "data:\(mime);base64,\(data.base64EncodedString())"
        }
    }

    private func fetchText(_ url: URL) async -> String? {
        guard let (data, _) = await Self.fetch(request(url, accept: "text/css,*/*;q=0.1"), session: session,
                                               limit: resourceLimit) else { return nil }
        var text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return text
    }

    private func request(_ url: URL, accept: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        for (field, value) in HTTPCookie.requestHeaderFields(with: jar.cookies(for: url) ?? []) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return request
    }

    /// The body and MIME type, or nil on failure, a sign-in page, or more than `limit` bytes.
    private static func fetch(_ request: URLRequest, session: URLSession, limit: Int) async -> (Data, String)? {
        guard let (bytes, response) = try? await session.bytes(for: request) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
        let mime = response.mimeType?.lowercased()
        if mime?.hasPrefix("text/html") == true || response.expectedContentLength > limit { return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > limit { return nil }
            }
        } catch {
            return nil
        }
        guard !data.isEmpty || mime == "text/css" else { return nil }
        let type = mime.flatMap { $0 == "application/octet-stream" ? nil : $0 }
            ?? request.url.flatMap { UTType(filenameExtension: $0.pathExtension)?.preferredMIMEType }
            ?? "application/octet-stream"
        return (data, type)
    }
}

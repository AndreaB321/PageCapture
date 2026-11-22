import Foundation
import os

/// Requests for a page's subresources (images, stylesheets, videos, documents) with the cookies and
/// Referer a browser would send for them (SPEC "Saving"), recomputed on every redirect:
///
/// - Cookies: those of the cookie jar that match the URL (domain, path, Secure, expiry), all of them
///   when the URL is same-site with the page, only `SameSite=None` ones when it is cross-site (no
///   policy counts as Lax). None once a redirect has gone from https to http.
/// - Referer: the page's full URL (without fragment) same-origin, its origin cross-origin, none from
///   an https page to an http URL or once a redirect has gone from https to http. The page's own
///   Referrer-Policy is not known here, so this is the default policy (`strict-origin-when-cross-origin`).
/// - Redirects to anything but http(s) are refused: the task ends with the redirect response.
///
/// Same-site compares registrable domains approximated without the Public Suffix List: the last two
/// labels of the host (the whole host for IP addresses and single labels). So `a.example.co.uk` and
/// `b.other.co.uk` count as same-site, which a browser would not do.
///
/// Use: `session.data(for: browser.request(url), delegate: browser.redirects())`. Set-by-hand headers
/// are never left to URLSession's redirect handling, which copies them to the next host.
struct BrowserRequest: Sendable {
    /// The page the resources belong to; nil for none (no Referer, the first URL decides the site).
    private(set) var page: URL?
    private let jar: HTTPCookieStorage

    init(page: URL?, cookies: [HTTPCookie]) {
        self.page = page
        // A private jar does the domain/path/Secure/expiry matching.
        jar = URLSessionConfiguration.ephemeral.httpCookieStorage ?? HTTPCookieStorage()
        for cookie in cookies { jar.setCookie(cookie) }
    }

    /// The same cookies for requests on behalf of another page.
    func onPage(_ page: URL?) -> BrowserRequest {
        var copy = self
        copy.page = page
        return copy
    }

    /// The first request for `url`; redirects keep its Accept header.
    func request(_ url: URL, accept: String? = nil) -> URLRequest {
        var request = request(url, first: url, downgraded: false)
        if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
        return request
    }

    /// A new delegate for each task, which rebuilds the request on every redirect.
    func redirects() -> URLSessionTaskDelegate {
        RedirectDelegate(browser: self)
    }

    /// The request for `url` in a chain that started at `first`.
    func request(_ url: URL, first: URL, downgraded: Bool) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        guard !downgraded else { return request }
        if let referer = referer(for: url) { request.setValue(referer, forHTTPHeaderField: "Referer") }
        for (field, value) in HTTPCookie.requestHeaderFields(with: cookies(for: url, first: first)) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return request
    }

    /// The jar's cookies for `url` that a browser sends with a subresource of the page.
    func cookies(for url: URL, first: URL) -> [HTTPCookie] {
        let matching = jar.cookies(for: url) ?? []
        guard let host = url.host, let pageHost = (page ?? first).host,
              Self.site(of: host) == Self.site(of: pageHost) else {
            return matching.filter { $0.sameSitePolicy?.rawValue.lowercased() == "none" }
        }
        return matching
    }

    /// The page's URL same-origin, its origin cross-origin, nil from https to http.
    func referer(for url: URL) -> String? {
        guard let page, let pageScheme = page.scheme?.lowercased() else { return nil }
        if pageScheme == "https", url.scheme?.lowercased() == "http" { return nil }
        var full = URLComponents(url: page, resolvingAgainstBaseURL: true)
        full?.fragment = nil
        full?.user = nil
        full?.password = nil
        guard let full else { return nil }
        if Self.origin(of: page) == Self.origin(of: url) { return full.string }
        guard let origin = Self.origin(of: page) else { return nil }
        return origin + "/"
    }

    /// `scheme://host[:port]`, without the scheme's default port; nil without a host.
    static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        let defaultPort = ["http": 80, "https": 443][scheme]
        let port = url.port.flatMap { $0 == defaultPort ? nil : $0 }
        let shownHost = host.contains(":") ? "[\(host)]" : host
        return "\(scheme)://\(shownHost)" + (port.map { ":\($0)" } ?? "")
    }

    /// The host's registrable domain, approximated: its last two labels (see the type's comment).
    static func site(of host: String) -> String {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let isIP = host.contains(":") || host.allSatisfy { $0.isNumber || $0 == "." }
        let labels = host.split(separator: ".")
        guard !isIP, labels.count > 2 else { return host }
        return labels.suffix(2).joined(separator: ".")
    }

    static func isHTTP(_ url: URL?) -> Bool {
        ["http", "https"].contains(url?.scheme?.lowercased() ?? "")
    }
}

/// Rebuilds each redirected request from scratch with `BrowserRequest`'s rules.
private final class RedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let browser: BrowserRequest
    /// Set once the chain went from https to http; then nothing more is sent.
    private let downgraded = OSAllocatedUnfairLock(initialState: false)

    init(browser: BrowserRequest) {
        self.browser = browser
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let url = request.url, BrowserRequest.isHTTP(url) else { return nil }
        let from = response.url ?? task.currentRequest?.url
        let downgraded = downgraded.withLock { downgraded in
            if from?.scheme?.lowercased() == "https", url.scheme?.lowercased() == "http" { downgraded = true }
            return downgraded
        }
        var next = browser.request(url, first: task.originalRequest?.url ?? url, downgraded: downgraded)
        next.httpMethod = request.httpMethod
        next.cachePolicy = request.cachePolicy
        next.timeoutInterval = request.timeoutInterval
        if let accept = task.originalRequest?.value(forHTTPHeaderField: "Accept") {
            next.setValue(accept, forHTTPHeaderField: "Accept")
        }
        return next
    }
}

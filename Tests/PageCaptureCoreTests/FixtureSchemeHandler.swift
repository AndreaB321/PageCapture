import WebKit

/// Serves the test fixtures for `pctest://<host>/…`: `index.html` and `frame.html` from `Fixtures/`,
/// a 1×1 PNG for any `.png`, and an empty stylesheet for any `.css`. Different hosts are different origins.
final class FixtureSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "pctest"
    private static let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let name = url.lastPathComponent
        let body: Data?
        let mime: String
        switch url.pathExtension {
        case "png":
            body = Self.png
            mime = "image/png"
        case "css":
            body = Data()
            mime = "text/css"
        default:
            let file = name == "index.html" ? "main.html" : name
            body = Bundle.module.url(forResource: "Fixtures/\(file)", withExtension: nil)
                .flatMap { try? Data(contentsOf: $0) }
            mime = "text/html"
        }
        guard let body else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: body.count, textEncodingName: "utf-8"))
        task.didReceive(body)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

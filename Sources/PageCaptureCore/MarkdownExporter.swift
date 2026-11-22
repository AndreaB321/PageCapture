import WebKit

/// HTML fragment → Markdown: `markdown.js` rewrites it as semantic HTML against a real (inert) DOM
/// in an off-screen web view, then the bundled MarkItDown (`DocumentConverter`) writes the Markdown.
@MainActor
public enum MarkdownExporter {
    /// - Parameter images: absolute image URL → path to use instead (`images/<file>`); other images
    ///   keep their remote URL.
    /// - Parameter videos: `data-pc-video` index → how that video's figure appears (a linked preview
    ///   image or caption); figures without an entry keep their poster and caption.
    /// - Parameter converter: runs MarkItDown; throws `DocumentConversionError.runtimeMissing` when
    ///   its Python is not there.
    public static func markdown(
        fromHTML html: String, images: [String: String], videos: [Int: VideoLink] = [:],
        converter: DocumentConverter = DocumentConverter()
    ) async throws -> String {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = OffscreenWebView(configuration: configuration)
        defer { view.close() }
        try await view.load(html: "<!doctype html><html><head></head><body></body></html>", baseURL: nil)
        try await view.run(CaptureScripts.chrome)
        try await view.run(CaptureScripts.markdown)
        let body = try await view.call(
            "return PageCaptureMarkdown.semanticHTML(html, images, videos);",
            arguments: ["html": html, "images": images, "videos": scriptVideos(videos)],
            as: String.self
        )
        let page = "<!doctype html><html><head><meta charset=\"utf-8\"></head><body>\(body)</body></html>"
        let markdown = try await converter.markdown(forCapturedPageHTML: page)
        return markdown.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// `markdown.js`'s `videos` option: keyed by the figure's `data-pc-video` value.
    static func scriptVideos(_ videos: [Int: VideoLink]) -> [String: [String: String]] {
        var out: [String: [String: String]] = [:]
        for (index, video) in videos {
            var entry = ["href": video.href, "title": video.title]
            entry["poster"] = video.posterFile
            entry["note"] = video.note
            out[String(index)] = entry
        }
        return out
    }
}

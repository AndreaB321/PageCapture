import WebKit

/// HTML fragment → Markdown, using `markdown.js` against a real (inert) DOM in an off-screen web view.
@MainActor
public enum MarkdownExporter {
    /// - Parameter images: absolute image URL → path to use instead (`images/<file>`); other images
    ///   keep their remote URL.
    /// - Parameter videos: `data-pc-video` index → how that video's figure appears (a linked preview
    ///   image or caption); figures without an entry keep their poster and caption.
    public static func markdown(
        fromHTML html: String, images: [String: String], videos: [Int: VideoLink] = [:]
    ) async throws -> String {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = OffscreenWebView(configuration: configuration)
        defer { view.close() }
        try await view.load(html: "<!doctype html><html><head></head><body></body></html>", baseURL: nil)
        try await view.run(CaptureScripts.chrome)
        try await view.run(CaptureScripts.markdown)
        return try await view.call(
            "return PageCaptureMarkdown.convert(html, images, videos);",
            arguments: ["html": html, "images": images, "videos": scriptVideos(videos)],
            as: String.self
        )
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

import Foundation
import WebKit

/// Writes a capture as one self-contained HTML file that looks like the page on screen (SPEC
/// "Saving"): built like the PDF's document (`document.js`) but without its print-only changes, with
/// inlined stylesheets, images embedded as `data:` URLs and no scripts. The site's header, navigation
/// and footer are left out as in the Markdown (`chrome.js`): at full window width the site's CSS would
/// show them beside the content. The content is then wrapped in the target's element and ancestors
/// (`CapturedContent.ancestors`, see `document.js` `wrap`), so the site's layout rules (classes on
/// `<html>`, rules on the column's parents) place it as on the page.
@MainActor
public enum HTMLExporter {
    /// - Parameters:
    ///   - stylesheets: the capture's stylesheets as self-contained CSS text (`StylesheetInliner`).
    ///   - localImages: absolute image URL → downloaded file; those images are embedded, the others
    ///     keep their remote URLs.
    ///   - configuration: base web view configuration for the off-screen document.
    ///   - videos: `data-pc-video` index → its link; saved videos link to `videos/<file>` next to `url`.
    public static func write(
        _ content: CapturedContent,
        stylesheets: [String],
        localImages: [String: URL],
        to url: URL,
        configuration: WKWebViewConfiguration,
        videos: [Int: VideoLink] = [:]
    ) async throws {
        let folder = url.deletingLastPathComponent()
        let configuration = configuration.copy() as! WKWebViewConfiguration
        // The captured page's own scripts must not run; the exporter's injected ones still do.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = OffscreenWebView(configuration: configuration)
        defer { view.close() }

        try await view.load(html: "<!doctype html><html><head></head><body></body></html>", baseURL: nil)
        try await view.run(CaptureScripts.chrome)
        try await view.run(CaptureScripts.document)
        let html = try await view.call(
            """
            PageCaptureDocument.build(options);
            PageCaptureChrome.remove(document.body, widgetRoles);
            PageCaptureDocument.wrap(shells);
            return PageCaptureDocument.standalone();
            """,
            arguments: ["options": [
                "html": content.html,
                "title": content.title,
                "sheets": stylesheets.map { ["css": $0] },
                "images": PDFExporter.dataURLs(for: localImages),
                "videos": scriptVideos(videos, folder: folder),
            ], "widgetRoles": widgetRoles, "shells": scriptShells(content.ancestors)],
            as: String.self)
        try Data(html.utf8).write(to: url, options: .atomic)
    }

    /// Roles left out besides the site's header, navigation and footer. Unlike the Markdown, tab bars
    /// stay (`document.js` hides them, and shows each tab's title over its panel).
    static let widgetRoles = ["dialog", "alertdialog", "menu", "menubar", "toolbar", "search"]

    /// `document.js` `wrap`'s argument.
    static func scriptShells(_ shells: [ElementShell]) -> [[String: Any]] {
        shells.map { ["tag": $0.tag, "attributes": $0.attributes] }
    }

    /// `document.js`'s `videos` option: saved videos link to their relative path, the others to the
    /// original; previews are embedded.
    static func scriptVideos(_ videos: [Int: VideoLink], folder: URL) -> [String: [String: String]] {
        var out: [String: [String: String]] = [:]
        for (index, video) in videos {
            let href = video.isLocal
                ? video.href.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? video.href
                : video.href
            var entry = ["href": href, "title": video.title]
            entry["poster"] = video.posterFile.flatMap { PDFExporter.dataURL(for: folder.appendingPathComponent($0)) }
            entry["note"] = video.note
            out[String(index)] = entry
        }
        return out
    }
}

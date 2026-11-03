import Foundation

/// The JavaScript sources injected into pages.
public enum CaptureScripts {
    /// Pure snapshot merge/dedup and serialisation (`merge.js`). Defines `PageCaptureMerge`.
    public static let merge = source(named: "merge")
    /// Picker and auto-scroll collector (`capture.js`). Needs `merge` loaded first.
    public static let capture = source(named: "capture")
    /// Leaves the site's header, navigation, footer and widgets out of a fragment (`chrome.js`), for
    /// the Markdown and the HTML file. Defines `PageCaptureChrome`.
    public static let chrome = source(named: "chrome")
    /// HTML fragment → Markdown (`markdown.js`). Defines `PageCaptureMarkdown`. Needs `chrome` loaded first.
    public static let markdown = source(named: "markdown")
    /// Builds the printable document for the PDF (`document.js`). Defines `PageCaptureDocument`.
    public static let document = source(named: "document")

    /// The app bundle copies the scripts into `Contents/Resources`; `swift run` and tests read
    /// them from the SwiftPM resource bundle.
    private static func source(named name: String) -> String {
        let url = Bundle.main.url(forResource: name, withExtension: "js")
            ?? Bundle.module.url(forResource: name, withExtension: "js")
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else {
            fatalError("Missing script resource \(name).js")
        }
        return text
    }
}

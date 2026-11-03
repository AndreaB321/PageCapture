import AppKit
import WebKit

/// Where the bundled manual is: `Manual/index.html` in the app's Resources (copied there from
/// `docs/manual` by scripts/build-app.sh).
public struct ManualLocation: Equatable, Sendable {
    /// The folder the web view may read: the page and its images.
    public let folder: URL
    public let index: URL

    public init(folder: URL) {
        self.folder = folder
        index = folder.appendingPathComponent("index.html")
    }

    /// The manual under `resources`, or nil when that has no `Manual/index.html`.
    public static func bundled(in resources: URL?) -> ManualLocation? {
        guard let resources else { return nil }
        let location = ManualLocation(folder: resources.appendingPathComponent("Manual", isDirectory: true))
        return FileManager.default.fileExists(atPath: location.index.path) ? location : nil
    }
}

/// What the manual window does with a link the user follows.
public enum ManualLinkPolicy: Equatable, Sendable {
    /// Load it in the manual window: the manual's own pages and anchors.
    case allow
    /// Hand it to the default browser.
    case openInBrowser
    /// Neither (other schemes).
    case cancel

    public static func decision(for url: URL?) -> ManualLinkPolicy {
        switch url?.scheme?.lowercased() {
        case "http", "https": .openInBrowser
        case "file", "about": .allow
        default: .cancel
        }
    }
}

/// Help > PageCapture Manual: one window showing the bundled manual, reused while it is open.
@MainActor
public final class ManualWindowController: NSObject, NSWindowDelegate, WKNavigationDelegate {
    public static let shared = ManualWindowController(location: .bundled(in: Bundle.main.resourceURL))

    private let location: ManualLocation?
    public private(set) var window: NSWindow?
    public private(set) var webView: WKWebView?
    /// Called each time a page finishes loading in the window.
    public var onFinishLoading: (() -> Void)?

    public init(location: ManualLocation?) {
        self.location = location
    }

    /// Brings the window forward, creating it (and loading the manual) when it is not open.
    public func show() {
        guard let location else {
            let alert = NSAlert()
            alert.messageText = "The manual is not available."
            alert.informativeText = "This build of PageCapture does not include it."
            alert.runModal()
            return
        }
        if window == nil { makeWindow(loading: location) }
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow(loading location: ManualLocation) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "PageCapture Manual"
        window.contentMinSize = NSSize(width: 480, height: 360)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.delegate = self
        window.center()
        self.window = window
        self.webView = webView
        webView.loadFileURL(location.index, allowingReadAccessTo: location.folder)
    }

    // MARK: NSWindowDelegate

    public func windowWillClose(_ notification: Notification) {
        window = nil
        webView = nil
    }

    // MARK: WKNavigationDelegate

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        switch ManualLinkPolicy.decision(for: url) {
        case .allow:
            decisionHandler(.allow)
        case .openInBrowser:
            if let url { NSWorkspace.shared.open(url) }
            decisionHandler(.cancel)
        case .cancel:
            decisionHandler(.cancel)
        }
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onFinishLoading?()
    }
}

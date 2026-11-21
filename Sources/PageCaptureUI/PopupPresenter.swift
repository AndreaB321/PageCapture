import AppKit
import WebKit

/// The parts of `WKWindowFeatures` a pop-up's size is read from, as plain values so it can be tested.
struct WindowFeatureValues: Equatable {
    var width: Double?
    var height: Double?

    init(width: Double? = nil, height: Double? = nil) {
        self.width = width
        self.height = height
    }

    @MainActor init(_ features: WKWindowFeatures) {
        self.init(width: features.width?.doubleValue, height: features.height?.doubleValue)
    }
}

/// A page's origin as plain values, so it can be tested: scheme, host, and the port when it is not
/// the scheme's default.
struct SiteOrigin: Equatable {
    var scheme: String
    var host: String
    var port: Int?

    init(scheme: String, host: String, port: Int? = nil) {
        self.scheme = scheme.lowercased()
        self.host = host
        let defaultPort = ["http": 80, "https": 443][self.scheme]
        self.port = port == 0 || port == defaultPort ? nil : port
    }

    init?(url: URL) {
        guard let scheme = url.scheme else { return nil }
        self.init(scheme: scheme, host: url.host() ?? "", port: url.port)
    }

    /// Nil for an opaque origin (a sandboxed frame), which has neither scheme nor host.
    @MainActor init?(_ origin: WKSecurityOrigin) {
        guard !origin.protocol.isEmpty else { return nil }
        self.init(scheme: origin.protocol, host: origin.host, port: origin.port)
    }

    /// "host" or "host:port"; the scheme for a URL without a host, such as a file.
    var text: String {
        guard !host.isEmpty else { return scheme }
        return port.map { "\(host):\($0)" } ?? host
    }

    var secure: Bool { scheme == "https" }
}

/// What happens when a page asks for a new window.
enum NewWindowPolicy: Equatable {
    /// Load the request in the web view that asked, as a normal navigation (back returns).
    case loadInPlace
    /// Open a pop-up window with the web view WebKit configured, so `window.opener` works.
    case openPopup

    static let defaultPopupSize = NSSize(width: 900, height: 700)
    /// Wide enough that the origin bar shows a long host's end next to "Not Secure".
    static let minimumPopupSize = NSSize(width: 400, height: 180)

    /// Only a link the user clicks (`target="_blank"`) loads in place, in the main window. Every window
    /// a script opens is a pop-up: WebKit does not report the `popup` feature, so `window.open(url)`
    /// cannot be told from a sign-in pop-up whose page needs `window.opener`. Anything a pop-up opens
    /// is another pop-up, so the page its opener waits on stays.
    static func decision(navigationType: WKNavigationType, fromPopup: Bool) -> NewWindowPolicy {
        navigationType == .linkActivated && !fromPopup ? .loadInPlace : .openPopup
    }

    /// Content size of a pop-up: the size the page asked for, or the default, kept between the minimum
    /// and `available`.
    static func popupSize(features: WindowFeatureValues, fitting available: NSSize) -> NSSize {
        func clamp(_ value: Double?, _ fallback: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
            min(max(value.map { CGFloat($0) } ?? fallback, low), max(low, high))
        }
        return NSSize(width: clamp(features.width, defaultPopupSize.width, minimumPopupSize.width, available.width),
                      height: clamp(features.height, defaultPopupSize.height, minimumPopupSize.height,
                                    available.height))
    }
}

/// The main web view's `WKUIDelegate`: opens new-window requests (in place or as pop-up windows) and
/// shows JavaScript alert, confirm and prompt panels. Pop-ups close when their page calls
/// `window.close()`, when the user closes them, or when the main window closes.
@MainActor
final class PopupPresenter: NSObject, WKUIDelegate {
    /// A pop-up window and the web view in it; the presenter's `popups` keeps it alive until it closes.
    @MainActor
    final class Popup: NSObject, NSWindowDelegate, WKNavigationDelegate {
        let webView: WKWebView
        let window: NSWindow
        private weak var presenter: PopupPresenter?
        private var observations: [NSKeyValueObservation] = []
        /// The URL of the page last committed in the pop-up. `webView.url` cannot be used: it reports a
        /// pending navigation's URL while the old page is still shown, and keeps it if the load fails.
        private var committedURL: URL?
        /// The opener's origin, kept while the pop-up only shows documents its opener made (about:blank,
        /// a data URL).
        private var creator: SiteOrigin?
        /// Where the page comes from, in a field of its own under the title bar. It is cut at its start,
        /// so the end of the host, the part a site cannot choose, always shows.
        let originField = NSTextField(labelWithString: "")
        private let securityField = NSTextField(labelWithString: "Not Secure")
        private let pageTitleField = NSTextField(labelWithString: "")

        /// The text that says where a page comes from, and whether it is served over https.
        struct OriginText: Equatable {
            var text: String
            var secure: Bool
        }

        /// Where the pop-up's page comes from: the host (and a port other than the scheme's default) of
        /// the committed URL. An about: page shows `creator`'s, a blob: URL the origin inside it, and a
        /// data: URL says what it is.
        static func origin(committedURL url: URL?, creator: SiteOrigin?) -> OriginText {
            let scheme = url?.scheme?.lowercased() ?? "about"
            switch scheme {
            case "about":
                return creator.map { OriginText(text: $0.text, secure: $0.secure) }
                    ?? OriginText(text: "about:blank", secure: false)
            case "data":
                return OriginText(text: creator.map { "data URL from \($0.text)" } ?? "data URL", secure: false)
            case "blob":
                let inner = url.flatMap { URL(string: String($0.absoluteString.dropFirst("blob:".count))) }
                guard let inner, let site = SiteOrigin(url: inner), !site.host.isEmpty
                else { return OriginText(text: "blob URL", secure: false) }
                return OriginText(text: site.text, secure: site.secure)
            default:
                guard let url, let site = SiteOrigin(url: url) else { return OriginText(text: scheme, secure: false) }
                return OriginText(text: site.text, secure: site.secure)
            }
        }

        /// The window title, used by the Window menu and accessibility: the origin always comes first,
        /// so a page cannot pass itself off as another site by its title, and a page not served over
        /// https says so.
        static func title(origin: OriginText, pageTitle: String?) -> String {
            var parts = [origin.text]
            if !origin.secure { parts.insert("Not Secure", at: 0) }
            if let pageTitle, !pageTitle.isEmpty { parts.append(pageTitle) }
            return parts.joined(separator: " — ")
        }

        init(webView: WKWebView, size: NSSize, opener: SiteOrigin?, presenter: PopupPresenter) {
            self.webView = webView
            self.presenter = presenter
            creator = opener
            window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
            super.init()
            // Released by dropping `popups`' reference, not by AppKit, so there is one owner.
            window.isReleasedWhenClosed = false
            window.contentView = webView
            window.contentMinSize = NewWindowPolicy.minimumPopupSize
            // The title bar would cut a long host at its end: the origin bar shows it instead.
            window.titleVisibility = .hidden
            window.addTitlebarAccessoryViewController(makeOriginBar())
            // The bar takes its height from the content: give the page the size it asked for.
            window.setContentSize(size)
            window.delegate = self
            webView.navigationDelegate = self
            observations = [
                webView.observe(\.title, options: [.new]) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.showOrigin() }
                },
            ]
            showOrigin()
        }

        /// The bar under the title bar: "Not Secure" (when so), the origin, then the page's title, which
        /// gives way first when the window is narrow. Both give way rather than widen the window, which
        /// constraints above `windowSizeStayPut` would do.
        private func makeOriginBar() -> NSTitlebarAccessoryViewController {
            originField.lineBreakMode = .byTruncatingHead
            originField.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            originField.setContentCompressionResistancePriority(.windowSizeStayPut - 10, for: .horizontal)
            securityField.textColor = .systemRed
            securityField.setContentCompressionResistancePriority(.required, for: .horizontal)
            pageTitleField.lineBreakMode = .byTruncatingTail
            pageTitleField.textColor = .secondaryLabelColor
            pageTitleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let stack = NSStackView(views: [securityField, originField, pageTitleField])
            stack.orientation = .horizontal
            stack.alignment = .firstBaseline
            stack.spacing = 8
            stack.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 6, right: 12)
            stack.detachesHiddenViews = true
            stack.frame.size = stack.fittingSize
            let bar = NSTitlebarAccessoryViewController()
            bar.layoutAttribute = .bottom
            bar.view = stack
            return bar
        }

        private func showOrigin() {
            let origin = Self.origin(committedURL: committedURL, creator: creator)
            originField.stringValue = origin.text
            securityField.isHidden = origin.secure
            pageTitleField.stringValue = webView.title ?? ""
            window.title = Self.title(origin: origin, pageTitle: webView.title)
        }

        /// Only a committed page changes the origin shown. A failed load leaves the last one; a
        /// same-document navigation (history.pushState, a #fragment) cannot change the origin.
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            committedURL = webView.url
            if let scheme = committedURL?.scheme?.lowercased(), scheme != "about", scheme != "data" {
                creator = nil
            }
            showOrigin()
            presenter?.pageDidChange(in: webView)
        }

        func windowWillClose(_ notification: Notification) {
            observations = []
            webView.stopLoading()
            webView.uiDelegate = nil
            webView.navigationDelegate = nil
            presenter?.remove(self)
        }
    }

    /// A JavaScript panel on screen. WebKit requires its completion handler to be called exactly once,
    /// also when the window it is on closes first.
    @MainActor
    final class OpenPanel {
        let alert: NSAlert
        private(set) weak var webView: WKWebView?
        private var completion: (@MainActor (NSApplication.ModalResponse) -> Void)?

        fileprivate init(alert: NSAlert, webView: WKWebView,
                         completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
            self.alert = alert
            self.webView = webView
            self.completion = completion
        }

        /// Calls the completion handler the first time; later calls do nothing.
        fileprivate func finish(_ response: NSApplication.ModalResponse) {
            guard let completion else { return }
            self.completion = nil
            completion(response)
        }
    }

    /// Panels shown to a web view since its page last changed, and whether the user turned the rest off.
    private struct PanelCount {
        var shown = 0
        var blocked = false
    }

    private weak var mainWebView: WKWebView?
    /// The open pop-ups, oldest first.
    private(set) var popups: [Popup] = []
    /// The JavaScript panels on screen, oldest first.
    private(set) var openPanels: [OpenPanel] = []
    private var panelCounts: [ObjectIdentifier: PanelCount] = [:]
    /// While this returns true, panels complete at once without being shown: alert with nothing,
    /// confirm with false, prompt with nil.
    var suppressPanels: @MainActor () -> Bool = { false }

    init(mainWebView: WKWebView) {
        self.mainWebView = mainWebView
        super.init()
        // Selector-based, so it is removed when the presenter goes.
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)),
                                               name: NSWindow.willCloseNotification, object: nil)
    }

    /// Closes every pop-up.
    func closeAll() {
        for popup in popups { popup.window.close() }
    }

    /// A new page committed in `webView`: its panels are counted afresh and may be shown again.
    func pageDidChange(in webView: WKWebView) {
        panelCounts[ObjectIdentifier(webView)] = nil
    }

    fileprivate func remove(_ popup: Popup) {
        finishPanels(in: popup.webView)
        pageDidChange(in: popup.webView)
        popups.removeAll { $0 === popup }
    }

    /// Pop-ups belong to the main window's page: they close with it.
    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let mainWebView, window === mainWebView.window
        else { return }
        closeAll()
        finishPanels(in: mainWebView)
    }

    // MARK: New windows

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let fromPopup = webView !== mainWebView
        switch NewWindowPolicy.decision(navigationType: navigationAction.navigationType, fromPopup: fromPopup) {
        case .loadInPlace:
            // A main-frame navigation like any other: it ends a capture in progress (see CaptureController).
            webView.load(navigationAction.request)
            return nil
        case .openPopup:
            // The pop-up starts on an empty document of the opener's origin, which the opener can write.
            return openPopup(configuration: configuration, features: WindowFeatureValues(windowFeatures),
                             opener: SiteOrigin(navigationAction.sourceFrame.securityOrigin),
                             over: mainWebView?.window)
        }
    }

    func webViewDidClose(_ webView: WKWebView) {
        popups.first { $0.webView === webView }?.window.close()
    }

    /// WebKit loads the request into the returned web view itself.
    private func openPopup(configuration: WKWebViewConfiguration, features: WindowFeatureValues,
                           opener: SiteOrigin?, over parent: NSWindow?) -> WKWebView {
        // `configuration` must be used as given: it links the pop-up to its opener.
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.uiDelegate = self
        let screen = (parent?.screen ?? NSScreen.main)?.visibleFrame
        let size = NewWindowPolicy.popupSize(features: features,
                                             fitting: screen?.size ?? NewWindowPolicy.defaultPopupSize)
        let popup = Popup(webView: webView, size: size, opener: opener, presenter: self)
        if let parent {
            let frame = popup.window.frame
            popup.window.setFrameOrigin(NSPoint(x: parent.frame.midX - frame.width / 2,
                                                y: parent.frame.midY - frame.height / 2))
        } else {
            popup.window.center()
        }
        popups.append(popup)
        popup.window.makeKeyAndOrderFront(nil)
        return webView
    }

    // MARK: JavaScript panels

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        guard let alert = panel(message, from: frame, in: webView) else { return completionHandler() }
        show(alert, in: webView) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        guard let alert = panel(message, from: frame, in: webView) else { return completionHandler(false) }
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        show(alert, in: webView) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor (String?) -> Void) {
        guard let alert = panel(prompt, from: frame, in: webView) else { return completionHandler(nil) }
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        show(alert, in: webView) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    /// The alert for a panel, or nil when it is not to be shown: during a capture, or after the user
    /// turned off this page's panels. From the second panel of a page on, the alert offers that.
    private func panel(_ message: String, from frame: WKFrameInfo, in webView: WKWebView) -> NSAlert? {
        guard !suppressPanels() else { return nil }
        var count = panelCounts[ObjectIdentifier(webView), default: PanelCount()]
        guard !count.blocked else { return nil }
        count.shown += 1
        panelCounts[ObjectIdentifier(webView)] = count
        let alert = NSAlert()
        let host = frame.securityOrigin.host
        alert.messageText = host.isEmpty ? "This page says:" : "\(host) says:"
        alert.informativeText = message
        if count.shown > 1 {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don't show more dialogs from this page"
        }
        return alert
    }

    /// As a sheet on the web view's window, or a modal panel when it has none.
    private func show(_ alert: NSAlert, in webView: WKWebView,
                      completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
        let open = OpenPanel(alert: alert, webView: webView) { [weak self, weak webView, weak alert] response in
            guard let self else { return completion(response) }
            openPanels.removeAll { $0.alert === alert }
            if alert?.suppressionButton?.state == .on, let webView {
                panelCounts[ObjectIdentifier(webView), default: PanelCount()].blocked = true
            }
            completion(response)
        }
        openPanels.append(open)
        guard let window = webView.window else {
            open.finish(alert.runModal())
            return
        }
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated { open.finish(response) }
        }
    }

    /// Ends every panel on screen as cancelled, which gives each its default answer: a capture is
    /// starting, and a panel left open would block its page.
    func finishAllPanels() {
        for open in openPanels { finish(open) }
    }

    /// Ends the panels shown to `webView` as cancelled, so their completion handlers are called.
    private func finishPanels(in webView: WKWebView) {
        for open in openPanels where open.webView === webView { finish(open) }
    }

    private func finish(_ open: OpenPanel) {
        if let window = open.webView?.window, let sheet = window.attachedSheet, sheet === open.alert.window {
            window.endSheet(sheet, returnCode: .cancel)
        }
        open.finish(.cancel)
    }
}

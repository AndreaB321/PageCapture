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

/// What happens when a page asks for a new window.
enum NewWindowPolicy: Equatable {
    /// Load the request in the web view that asked, as a normal navigation (back returns).
    case loadInPlace
    /// Open a pop-up window with the web view WebKit configured, so `window.opener` works.
    case openPopup

    static let defaultPopupSize = NSSize(width: 900, height: 700)
    static let minimumPopupSize = NSSize(width: 240, height: 180)

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

        /// The window title: the page's host always comes first, so a page cannot pass itself off as
        /// another site by its title, and a page not served over https says so.
        static func title(url: URL?, pageTitle: String?) -> String {
            let host = url?.host().flatMap { $0.isEmpty ? nil : $0 }
            var parts = [host ?? url?.scheme ?? "about"]
            if url?.scheme?.lowercased() != "https" { parts.insert("Not Secure", at: 0) }
            if let pageTitle, !pageTitle.isEmpty { parts.append(pageTitle) }
            return parts.joined(separator: " — ")
        }

        init(webView: WKWebView, size: NSSize, presenter: PopupPresenter) {
            self.webView = webView
            self.presenter = presenter
            window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
            super.init()
            // Released by dropping `popups`' reference, not by AppKit, so there is one owner.
            window.isReleasedWhenClosed = false
            window.contentView = webView
            window.delegate = self
            webView.navigationDelegate = self
            observations = [
                webView.observe(\.url, options: [.initial, .new]) { [weak window] webView, _ in
                    MainActor.assumeIsolated { window?.title = Self.title(url: webView.url, pageTitle: webView.title) }
                },
                webView.observe(\.title, options: [.new]) { [weak window] webView, _ in
                    MainActor.assumeIsolated { window?.title = Self.title(url: webView.url, pageTitle: webView.title) }
                },
            ]
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
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
            return openPopup(configuration: configuration, features: WindowFeatureValues(windowFeatures),
                             over: mainWebView?.window)
        }
    }

    func webViewDidClose(_ webView: WKWebView) {
        popups.first { $0.webView === webView }?.window.close()
    }

    /// WebKit loads the request into the returned web view itself.
    private func openPopup(configuration: WKWebViewConfiguration, features: WindowFeatureValues,
                           over parent: NSWindow?) -> WKWebView {
        // `configuration` must be used as given: it links the pop-up to its opener.
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.uiDelegate = self
        let screen = (parent?.screen ?? NSScreen.main)?.visibleFrame
        let size = NewWindowPolicy.popupSize(features: features,
                                             fitting: screen?.size ?? NewWindowPolicy.defaultPopupSize)
        let popup = Popup(webView: webView, size: size, presenter: self)
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

    /// Ends the panels shown to `webView` as cancelled, so their completion handlers are called.
    private func finishPanels(in webView: WKWebView) {
        for open in openPanels where open.webView === webView {
            if let window = webView.window, let sheet = window.attachedSheet, sheet === open.alert.window {
                window.endSheet(sheet, returnCode: .cancel)
            }
            open.finish(.cancel)
        }
    }
}

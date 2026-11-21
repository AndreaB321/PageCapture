import AppKit
import WebKit

/// The parts of `WKWindowFeatures` the new-window decision reads, as plain values so it can be tested.
struct WindowFeatureValues: Equatable {
    var width: Double?
    var height: Double?
    var x: Double?
    var y: Double?
    var menuBar: Bool?
    var statusBar: Bool?
    var toolbars: Bool?
    var resizing: Bool?

    init(width: Double? = nil, height: Double? = nil, x: Double? = nil, y: Double? = nil,
         menuBar: Bool? = nil, statusBar: Bool? = nil, toolbars: Bool? = nil, resizing: Bool? = nil) {
        self.width = width
        self.height = height
        self.x = x
        self.y = y
        self.menuBar = menuBar
        self.statusBar = statusBar
        self.toolbars = toolbars
        self.resizing = resizing
    }

    @MainActor init(_ features: WKWindowFeatures) {
        self.init(width: features.width?.doubleValue, height: features.height?.doubleValue,
                  x: features.x?.doubleValue, y: features.y?.doubleValue,
                  menuBar: features.menuBarVisibility?.boolValue, statusBar: features.statusBarVisibility?.boolValue,
                  toolbars: features.toolbarsVisibility?.boolValue, resizing: features.allowsResizing?.boolValue)
    }

    /// The page asked for a window of its own shape: a size or position, or bars turned off.
    /// `target="_blank"` and `window.open(url)` ask for none of these.
    var describesPopup: Bool {
        width != nil || height != nil || x != nil || y != nil
            || [menuBar, statusBar, toolbars, resizing].contains(false)
    }
}

/// What happens when a page asks for a new window.
enum NewWindowPolicy: Equatable {
    /// Load the request in the web view that asked, as a normal navigation (back returns).
    case loadInPlace
    /// Open a pop-up window with the web view WebKit configured, so `window.opener` works.
    case openPopup

    static let defaultPopupSize = NSSize(width: 500, height: 640)
    static let minimumPopupSize = NSSize(width: 240, height: 180)

    /// A pop-up for window features or a blank window (the opener fills it in by script); otherwise
    /// in place. Anything a pop-up opens is another pop-up, so the page its opener waits on stays.
    static func decision(url: URL?, features: WindowFeatureValues, fromPopup: Bool) -> NewWindowPolicy {
        if fromPopup || features.describesPopup { return .openPopup }
        let isBlank = url == nil || url?.absoluteString.isEmpty == true || url?.absoluteString == "about:blank"
        return isBlank ? .openPopup : .loadInPlace
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
    final class Popup: NSObject, NSWindowDelegate {
        let webView: WKWebView
        let window: NSWindow
        private weak var presenter: PopupPresenter?
        private var titleObservation: NSKeyValueObservation?

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
            titleObservation = webView.observe(\.title, options: [.initial, .new]) { [weak window] webView, _ in
                MainActor.assumeIsolated {
                    window?.title = webView.title.flatMap { $0.isEmpty ? nil : $0 } ?? webView.url?.host() ?? ""
                }
            }
        }

        func windowWillClose(_ notification: Notification) {
            titleObservation = nil
            webView.stopLoading()
            webView.uiDelegate = nil
            presenter?.remove(self)
        }
    }

    private weak var mainWebView: WKWebView?
    /// The open pop-ups, oldest first.
    private(set) var popups: [Popup] = []

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

    fileprivate func remove(_ popup: Popup) {
        popups.removeAll { $0 === popup }
    }

    /// Pop-ups belong to the main window's page: they close with it.
    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let mainWindow = mainWebView?.window,
              window === mainWindow else { return }
        closeAll()
    }

    // MARK: New windows

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let features = WindowFeatureValues(windowFeatures)
        let fromPopup = webView !== mainWebView
        switch NewWindowPolicy.decision(url: navigationAction.request.url, features: features, fromPopup: fromPopup) {
        case .loadInPlace:
            // A main-frame navigation like any other: it ends a capture in progress (see CaptureController).
            webView.load(navigationAction.request)
            return nil
        case .openPopup:
            return openPopup(configuration: configuration, features: features, over: mainWebView?.window)
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
        let alert = panel(message, from: frame)
        show(alert, in: webView) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        let alert = panel(message, from: frame)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        show(alert, in: webView) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor (String?) -> Void) {
        let alert = panel(prompt, from: frame)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        show(alert, in: webView) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    private func panel(_ message: String, from frame: WKFrameInfo) -> NSAlert {
        let alert = NSAlert()
        let host = frame.securityOrigin.host
        alert.messageText = host.isEmpty ? "This page says:" : "\(host) says:"
        alert.informativeText = message
        return alert
    }

    /// As a sheet on the web view's window, or a modal panel when it has none.
    private func show(_ alert: NSAlert, in webView: WKWebView,
                      completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
        guard let window = webView.window else {
            completion(alert.runModal())
            return
        }
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated { completion(response) }
        }
    }
}

import WebKit

/// Pacing of the auto-scroll collector (see `capture.js`).
public struct CollectionTiming: Sendable {
    /// Scroll step as a fraction of the target's visible height.
    public var stepRatio: Double = 0.8
    /// Wait after each scroll step, in milliseconds.
    public var settleDelay: Int = 300
    /// Longer wait used while the target appears to be at its end, giving more content time to load.
    public var stallDelay: Int = 800
    /// Upper bound on waiting for images in view to load, in milliseconds.
    public var imageTimeout: Int = 2000
    /// Consecutive attempts without scrolling or new content before the capture ends.
    public var stallLimit: Int = 3
    /// Upper bound on playing a video to reveal its source, or on waiting for a clicked player's
    /// video to appear, in milliseconds.
    public var videoRevealTimeout: Int = 3000
    /// Upper bound on waiting for a tab or accordion panel's content to arrive after it is shown
    /// (while it is empty, shows a loading indicator or keeps changing), in milliseconds.
    public var panelLoadTimeout: Int = 5000
    /// Upper bound on all such waits in one capture, beyond the short pause after each click, in
    /// milliseconds.
    public var panelWaitBudget: Int = 30000

    public init() {}
}

public enum PageCaptureError: Error, Equatable {
    case noWebView
    case nothingPicked
    case unexpectedResult
}

/// Connects a WKWebView to the injected picker/collector scripts. Every frame (cross-origin iframes
/// included) runs the scripts in a dedicated content world and registers itself here, so the picker
/// can be switched on everywhere and the collector run in the frame the user picked.
@MainActor
public final class PageCaptureBridge {
    public static let contentWorld = WKContentWorld.world(name: "PageCapture")
    static let handlerName = "pageCapture"
    /// Handler that replies: a capture asks it for the videos in its child frames.
    static let askHandlerName = "pageCaptureAsk"
    /// How long to wait for child frames to report the tokens their parent named them with.
    static let frameTokenWait: Duration = .seconds(2)
    /// Upper bound on one child frame's `frameVideos()`, which may play several videos.
    static let frameVideosTimeout: Duration = .seconds(30)

    /// Called when the user clicks a target in picker mode.
    public var onPick: ((CaptureTarget) -> Void)?
    /// Called instead of `onPick` when the user clicks a document whose original cannot be saved
    /// (SPEC "Documents"); `collect(.picked)` then captures it as a page.
    public var onDocumentUnavailable: ((DocumentDownloadError) -> Void)?

    public weak var webView: WKWebView?

    /// Frames that have announced themselves since the last main-frame document started.
    private(set) var knownFrames: [WKFrameInfo] = []
    /// Child frames by the token their parent frame named them with (see `capture.js`).
    private var framesByToken: [String: WKFrameInfo] = [:]
    private var isPicking = false
    /// Bumped whenever picking starts or stops, so a late PDF.js check is ignored.
    private var pickingSession = 0
    /// The PDF.js viewers found since picking started (see `findPDFViewer`): the PDF each shows, and
    /// how much of the view (CSS px²) it covers.
    private(set) var pdfViewers: [(url: URL, area: Double)] = []
    /// What `collect(.picked)` collects (also when a picked document falls back to a page).
    private var picked: PickedArea?
    /// Whether the pick is the whole page, for the result message when a document falls back to a page.
    public var pickedWholePage: Bool { picked == .wholePage }
    /// The main frame's last response, so a page that is itself a document is one (see `pickWholePage()`).
    private var mainFrameResponse: (url: URL?, mimeType: String?)?
    private var collectingFrame: WKFrameInfo?
    private var isCollecting = false
    /// Bumped to orphan a collection that never completes (see `abortCollection`).
    private var collectionID = 0
    /// A stop asked for before the collector had started; sent right after it starts.
    private var pendingStop = false

    public init() {}

    /// Installs the scripts and the message handler. Call before creating the web view.
    public func install(in configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
        for source in [CaptureScripts.merge, CaptureScripts.capture] {
            controller.addUserScript(WKUserScript(
                source: source,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false,
                in: Self.contentWorld
            ))
        }
        controller.add(MessageProxy(bridge: self), contentWorld: Self.contentWorld, name: Self.handlerName)
        controller.addScriptMessageHandler(AskProxy(bridge: self), contentWorld: Self.contentWorld,
                                           name: Self.askHandlerName)
    }

    // MARK: Picker

    public func setPicking(_ on: Bool) {
        isPicking = on
        pickingSession += 1
        pdfViewers = []
        for frame in knownFrames {
            run("globalThis.__pageCapture.setPicking(\(on))", in: frame)
            if on { findPDFViewer(in: frame) }
        }
    }

    /// Reads, in the page's own world, whether `frame` runs PDF.js and which PDF its standard viewer
    /// names; the frame's script then finds the PDF and remembers it for a click (see `capture.js`).
    private static let pdfjsProbe = """
        try {
          const app = window.PDFViewerApplication;
          if (!window.pdfjsLib && !app) return null;
          const urls = [];
          if (app && typeof app.url === 'string') urls.push(app.url);
          if (app && typeof app.baseUrl === 'string') urls.push(app.baseUrl);
          return urls;
        } catch (e) { return null; }
        """

    private func findPDFViewer(in frame: WKFrameInfo) {
        let session = pickingSession
        Task {
            guard let urls = await evaluate(Self.pdfjsProbe, arguments: [:], in: frame, world: .page,
                                            timeout: Self.frameTokenWait, as: { $0 as? [String] }),
                  session == pickingSession,
                  let viewer = await evaluate("return globalThis.__pageCapture.pdfViewer(urls);",
                                              arguments: ["urls": urls], in: frame, timeout: Self.frameTokenWait,
                                              as: Self.viewer),
                  session == pickingSession else { return }
            pdfViewers.append(viewer)
        }
    }

    private nonisolated static func viewer(_ value: Any) -> (url: URL, area: Double)? {
        guard let dict = value as? [String: Any], let src = dict["url"] as? String, let url = URL(string: src),
              let area = (dict["area"] as? NSNumber)?.doubleValue else { return nil }
        return (url, area)
    }

    /// The PDF of the only PDF.js viewer the user can see, when it covers at least half of the view.
    /// Viewers are told apart by their PDF: a frame can be listed twice (it announces each document
    /// it loads, the `about:blank` one before its own, and both answer from its current one).
    private func coveringPDFViewer() -> URL? {
        guard let webView else { return nil }
        var areas: [URL: Double] = [:]
        for viewer in pdfViewers where viewer.area > 0 { areas[viewer.url] = max(areas[viewer.url] ?? 0, viewer.area) }
        let zoom = webView.pageZoom * webView.magnification
        let viewArea = Double(webView.bounds.width * webView.bounds.height / (zoom * zoom))
        guard areas.count == 1, let (url, area) = areas.first, viewArea > 0, area >= viewArea / 2 else { return nil }
        return url
    }

    // MARK: Collection

    /// Auto-scrolls the target and returns what was collected. Ends at the bottom or after `stopCollection()`.
    public func collect(_ target: CaptureTarget, timing: CollectionTiming = .init()) async throws -> CapturedContent {
        guard let webView else { throw PageCaptureError.noWebView }
        let frame: WKFrameInfo?
        let wholeDocument: Bool
        switch target {
        case .wholePage: (frame, wholeDocument) = (nil, true)
        case .picked, .document: // a document is collected as a page when it falls back
            switch picked {
            case nil: throw PageCaptureError.nothingPicked
            case .wholePage: (frame, wholeDocument) = (nil, true)
            case .element(let pickedFrame): (frame, wholeDocument) = (pickedFrame, false)
            case .frameDocument(let token, let surrounding):
                if let child = await childFrame(token: token) {
                    (frame, wholeDocument) = (child, true)
                } else if case .element(let pickedFrame) = surrounding {
                    (frame, wholeDocument) = (pickedFrame, false)
                } else {
                    (frame, wholeDocument) = (nil, true)
                }
            }
        }
        let options: [String: Any] = [
            "wholePage": wholeDocument,
            "stepRatio": timing.stepRatio,
            "settleDelay": timing.settleDelay,
            "stallDelay": timing.stallDelay,
            "imageTimeout": timing.imageTimeout,
            "stallLimit": timing.stallLimit,
            "revealTimeout": timing.videoRevealTimeout,
            "panelTimeout": timing.panelLoadTimeout,
            "panelWaitBudget": timing.panelWaitBudget,
        ]
        collectingFrame = frame
        isCollecting = true
        collectionID += 1
        let id = collectionID
        defer { if id == collectionID { isCollecting = false; collectingFrame = nil; pendingStop = false } }

        let json: String = try await withCheckedThrowingContinuation { continuation in
            webView.callAsyncJavaScript(
                "return await globalThis.__pageCapture.capture(options);",
                arguments: ["options": options],
                in: frame,
                in: Self.contentWorld
            ) { result in
                switch result {
                case .success(let value as String): continuation.resume(returning: value)
                case .success: continuation.resume(throwing: PageCaptureError.unexpectedResult)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
            if pendingStop {
                pendingStop = false
                run("globalThis.__pageCapture.stop()", in: frame)
            }
        }
        var content = try CapturedContent(collectorJSON: json)
        if content.title.isEmpty, let pageTitle = webView.title { content.title = pageTitle }
        return content
    }

    /// Asks a running collection to end; `collect` then returns what it has.
    /// A stop that arrives before the collection has started is remembered and applied as it starts.
    public func stopCollection() {
        guard isCollecting else {
            pendingStop = true
            return
        }
        run("globalThis.__pageCapture.stop()", in: collectingFrame)
    }

    /// Gives up on a running collection (e.g. the page navigated away and the script call may never
    /// complete). Its eventual result, if any, is the caller's to ignore.
    public func abortCollection() {
        pendingStop = false
        collectionID += 1
        isCollecting = false
        collectingFrame = nil
    }

    // MARK: Documents

    /// Records the main frame's response (from the navigation delegate's `decidePolicyFor
    /// navigationResponse`), so `pickWholePage()` knows when the page itself is a PDF.
    public func noteMainFrameResponse(_ response: URLResponse) {
        mainFrameResponse = (response.url, response.mimeType)
    }

    /// Picks the whole page (Return, or a click outside any target) and returns the event for it:
    /// a page that is itself a document, or the PDF.js viewer that fills most of it, is picked as
    /// the document (SPEC "Documents").
    public func pickWholePage() -> CaptureEvent {
        picked = .wholePage
        guard let url = webView?.url else { return .picked(.wholePage) }
        if let event = Self.event(for: pageDocument(url)) { return event }
        if let pdf = coveringPDFViewer(),
           let event = Self.event(for: DocumentSource.detect(url: pdf, mimeType: "application/pdf")) {
            return event
        }
        return .picked(.wholePage)
    }

    /// The document the page at `url` itself is, if any.
    private func pageDocument(_ url: URL) -> DocumentDetection? {
        let mimeType = mainFrameResponse.flatMap { Self.samePage($0.url, url) ? $0.mimeType : nil }
            .flatMap { DocumentKind.genericMIMETypes.contains(DocumentKind.essence(of: $0)) ? nil : $0 }
        // A known type that is not a document type makes it a page, whatever its URL looks like
        // (`…/blob/main/paper.pdf` served as HTML).
        if let mimeType, !mimeType.isEmpty, DocumentKind(mimeType: mimeType) == nil,
           DocumentKind.unsupportedMIMETypes[DocumentKind.essence(of: mimeType)] == nil {
            return nil
        }
        return DocumentSource.detect(url: url, mimeType: mimeType)
    }

    private static func event(for detection: DocumentDetection?) -> CaptureEvent? {
        switch detection {
        case .document(let source): .picked(.document(source))
        case .unavailable(let reason): .documentUnavailable(reason)
        case nil: nil
        }
    }

    /// The same document, whatever its fragment.
    private static func samePage(_ a: URL?, _ b: URL) -> Bool {
        func strip(_ url: URL) -> String {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.fragment = nil
            return components?.string ?? url.absoluteString
        }
        return a.map(strip) == strip(b)
    }

    private func deliver(_ event: CaptureEvent) {
        switch event {
        case .picked(let target): onPick?(target)
        case .documentUnavailable(let reason): onDocumentUnavailable?(reason)
        default: break
        }
    }

    /// The child frame its parent named `token`, waiting a moment for it to report (see `capture.js`).
    private func childFrame(token: String) async -> WKFrameInfo? {
        let deadline = ContinuousClock.now + Self.frameTokenWait
        while framesByToken[token] == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return framesByToken[token]
    }

    // MARK: Messages

    fileprivate func receive(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        let frame = message.frameInfo
        switch type {
        case "frameReady":
            if frame.isMainFrame {
                knownFrames.removeAll()
                framesByToken.removeAll()
                pdfViewers.removeAll()
            }
            knownFrames.append(frame)
            if isPicking {
                run("globalThis.__pageCapture.setPicking(true)", in: frame)
                findPDFViewer(in: frame)
            }
        case "picked":
            guard isPicking else { return }
            // What was clicked, or what surrounds the embedded document that was.
            let area: PickedArea = body["kind"] as? String == "wholePage" ? .wholePage : .element(frame)
            if let src = body["src"] as? String, let url = URL(string: src),
               let event = Self.event(for: DocumentSource.detect(url: url, mimeType: body["mimeType"] as? String)) {
                // Its frame's own document is the page to capture if the original cannot be saved.
                picked = (body["frameToken"] as? String).map { .frameDocument(token: $0, surrounding: area) } ?? area
                deliver(event)
            } else if area == .wholePage {
                deliver(pickWholePage())
            } else {
                picked = area
                onPick?(.picked)
            }
        case "frameToken":
            if let token = body["token"] as? String { framesByToken[token] = frame }
        default:
            break
        }
    }

    /// Answers a capture's `frameVideos` request: runs `frameVideos()` in each child frame it names
    /// and returns `[token: JSON array]` for the frames that answered.
    fileprivate func answer(_ message: WKScriptMessage) async -> [String: String] {
        guard let body = message.body as? [String: Any], body["type"] as? String == "frameVideos",
              let tokens = body["tokens"] as? [String] else { return [:] }
        let options = body["options"] as? [String: Any] ?? [:]
        let clock = ContinuousClock()
        let deadline = clock.now + Self.frameTokenWait
        var result: [String: String] = [:]
        for token in tokens {
            while framesByToken[token] == nil, clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard let frame = framesByToken[token] else { continue }
            if let json = await evaluate("return await globalThis.__pageCapture.frameVideos(options);",
                                         arguments: ["options": options], in: frame,
                                         timeout: Self.frameVideosTimeout, as: { $0 as? String }) {
                result[token] = json
            }
        }
        return result
    }

    /// Runs `script` in `frame` (in this bridge's content world unless `world` says otherwise) and
    /// converts its result, giving up after `timeout` (a frame that navigates away may never answer).
    private func evaluate<T: Sendable>(_ script: String, arguments: [String: Any], in frame: WKFrameInfo,
                                       world: WKContentWorld = PageCaptureBridge.contentWorld, timeout: Duration,
                                       as convert: @escaping @MainActor (Any) -> T?) async -> T? {
        guard let webView else { return nil }
        return await withCheckedContinuation { continuation in
            let once = Once(continuation)
            webView.callAsyncJavaScript(script, arguments: arguments, in: frame, in: world) { result in
                once.resume(returning: (try? result.get()).flatMap(convert))
            }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                once.resume(returning: nil)
            }
        }
    }

    /// Fire-and-forget evaluation; frames that have gone away just report an error.
    private func run(_ script: String, in frame: WKFrameInfo?) {
        webView?.evaluateJavaScript(script, in: frame, in: Self.contentWorld) { _ in }
    }
}

/// What the user picked, for `collect(.picked)`.
private enum PickedArea: Equatable {
    case wholePage
    /// A scrollable area, main content or frame document, which the frame's script remembers.
    case element(WKFrameInfo)
    /// An embedded document's frame, named `token` by its parent (see `capture.js`); `surrounding`
    /// when that frame runs no script (it shows a plugin, or failed to load).
    indirect case frameDocument(token: String, surrounding: PickedArea)
}

/// Resumes a continuation once, whichever of its callers comes first.
@MainActor
private final class Once<T: Sendable> {
    private var continuation: CheckedContinuation<T?, Never>?

    init(_ continuation: CheckedContinuation<T?, Never>) {
        self.continuation = continuation
    }

    func resume(returning value: T?) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

/// Breaks the retain cycle between the user content controller and the bridge.
private final class MessageProxy: NSObject, WKScriptMessageHandler {
    weak var bridge: PageCaptureBridge?

    init(bridge: PageCaptureBridge) {
        self.bridge = bridge
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { bridge?.receive(message) }
    }
}

/// Like `MessageProxy`, for the handler that replies.
private final class AskProxy: NSObject, WKScriptMessageHandlerWithReply {
    weak var bridge: PageCaptureBridge?

    init(bridge: PageCaptureBridge) {
        self.bridge = bridge
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        MainActor.assumeIsolated {
            guard let bridge else { return replyHandler(nil, nil) }
            Task { @MainActor in replyHandler(await bridge.answer(message), nil) }
        }
    }
}

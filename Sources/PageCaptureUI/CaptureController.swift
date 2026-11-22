import AppKit
import Observation
import PageCaptureCore
import WebKit

/// Owns the web view and runs the capture flow: feeds events to the state machine and performs its effects.
@MainActor
@Observable
public final class CaptureController {
    public private(set) var machine = CaptureStateMachine()
    public let webView: WKWebView
    @ObservationIgnored private let bridge = PageCaptureBridge()
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var collected: CapturedContent?
    @ObservationIgnored private let navigationDelegate = NavigationDelegate()
    /// Bumped when a collection is aborted, so its late result is ignored.
    @ObservationIgnored private var collectionGeneration = 0
    /// The picked document's download, while it runs (SPEC "Documents").
    @ObservationIgnored private var documentDownload: Task<Void, Never>?
    /// Download tasks that have not ended yet, cancelled ones included (they remove their files as they end).
    @ObservationIgnored private var runningDownloads = 0
    /// The downloaded original, from its download until it is discarded: after its save, when the
    /// save panel is cancelled, or when the app quits (`cancelDocumentDownload`).
    @ObservationIgnored private var downloaded: DownloadedDocument?

    /// Base configuration of the document download; tests add a `URLProtocol`.
    @ObservationIgnored var documentSessionConfiguration = URLSessionConfiguration.ephemeral
    /// Where the downloaded original waits; tests use their own folder.
    @ObservationIgnored var documentTemporaryRoot = VideoDownloader.defaultTemporaryRoot
    @ObservationIgnored var documentConverter = DocumentConverter()
    /// Tests replace the save panel and the result message, which need a window.
    @ObservationIgnored var savePanelOverride: ((SaveRequest) async -> SaveChoice?)?
    @ObservationIgnored var messageOverride: ((NSAlert) -> Void)?

    /// Where the save panel's format choice is remembered.
    @ObservationIgnored private let defaults: UserDefaults

    /// The app uses the defaults; the manual's screenshot harness passes a non-persistent store and
    /// its own defaults so it leaves the app's data alone.
    /// Folder the save panel opens in; nil keeps the panel's own memory (the app never sets it).
    public var initialSaveDirectory: URL?

    public init(dataStore: WKWebsiteDataStore = .default(), defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        bridge.install(in: configuration)
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        bridge.webView = webView
        bridge.onPick = { [weak self] target in self?.send(.picked(target)) }
        bridge.onDocumentUnavailable = { [weak self] reason in self?.send(.documentUnavailable(reason)) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let keyCode = event.keyCode
            let characters = event.charactersIgnoringModifiers
            let flags = event.modifierFlags
            // Consuming ⌘⇧S here also keeps the menu item from firing it a second time.
            let consumed = MainActor.assumeIsolated { self.handleKey(keyCode, characters: characters, flags: flags) }
            return consumed ? nil : event
        }
        navigationDelegate.onCommit = { [weak self] in self?.send(.navigated) }
        navigationDelegate.onMainFrameResponse = { [weak self] response in self?.bridge.noteMainFrameResponse(response) }
        webView.navigationDelegate = navigationDelegate
    }

    /// Banner while the export runs after the save panel closes.
    private(set) var savingText: String?

    public var bannerText: String? { machine.bannerText ?? savingText }

    public var shortcutTitle: String {
        switch machine.phase {
        case .idle, .saving: "Capture Frame or Page"
        case .picking: "Cancel Picking"
        case .capturing: "Stop Capture"
        case .stopping: "Abort Capture"
        case .downloadingDocument: "Cancel Download"
        }
    }

    public var shortcutEnabled: Bool {
        switch machine.phase {
        case .idle, .picking, .capturing, .stopping, .downloadingDocument: true
        case .saving: false
        }
    }

    public func send(_ event: CaptureEvent) {
        // Return picks the whole page, which may itself be a document.
        let event = event == .returnKey && machine.phase == .picking ? bridge.pickWholePage() : event
        for effect in machine.handle(event) {
            perform(effect)
        }
    }

    /// Saves the capture: save panel (with the format checkboxes), then the export pipeline, then a
    /// message with where it went.
    func didFinishCapture(_ content: CapturedContent) {
        // The picked document that could not be downloaded, for the message.
        let documentFallback = machine.documentFallback
        // Whether that document was the page itself (Return, or a click outside any target) or a frame in it.
        let documentFallbackIsWholePage = bridge.pickedWholePage
        let request = SaveRequest(title: "Save Capture", message: "Creates a folder with the files and an images folder.",
                                  name: ExportNaming.sanitizedName(fromTitle: content.title), kind: .page)
        Task {
            guard let choice = await chooseSave(request) else {
                send(.saveFinished)
                return
            }
            exportTask = Task {
                await finishExport(title: "Capture saved", failure: "The capture could not be saved.") {
                    var result = try await CaptureExporter.export(content, formats: choice.formats, to: choice.folder) {
                        let configuration = WKWebViewConfiguration()
                        configuration.websiteDataStore = self.webView.configuration.websiteDataStore
                        return configuration
                    }
                    result.documentFallback = documentFallback
                    result.documentFallbackIsWholePage = documentFallbackIsWholePage
                    return result
                }
            }
        }
    }

    /// Saves a downloaded document: save panel with the document formats, then its original and/or
    /// Markdown, then the message (SPEC "Documents").
    private func saveDocument(_ document: DownloadedDocument) {
        let request = SaveRequest(title: "Save Document", message: "Creates a folder with the original and/or its Markdown.",
                                  name: ExportNaming.documentName(url: document.source.url, pageTitle: webView.title),
                                  kind: .document, original: document.source.kind)
        Task {
            guard let choice = await chooseSave(request) else {
                discard(document)
                send(.saveFinished)
                return
            }
            exportTask = Task {
                await finishExport(title: "Document saved", failure: "The document could not be saved.") {
                    defer { self.discard(document) }
                    return try await DocumentExporter.export(document.file, kind: document.source.kind,
                                                             formats: choice.formats, to: choice.folder,
                                                             downloadedFrom: document.source.url, page: document.page,
                                                             converter: self.documentConverter)
                }
            }
        }
    }

    /// The export running after the save panel closed; nil once its outputs are written.
    @ObservationIgnored private var exportTask: Task<Void, Never>?

    public var isExporting: Bool { exportTask != nil }

    /// Cancels the running export (which stops its tools) and waits until it has stopped, or `limit` passed.
    public func cancelExport(waitingAtMost limit: Duration) async {
        exportTask?.cancel()
        let deadline = ContinuousClock.now + limit
        while exportTask != nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// A document is being downloaded, or waits in the save panel.
    public var isDownloadingDocument: Bool { runningDownloads > 0 || downloaded != nil }

    /// Cancels a document download (quitting) and waits until its file is removed, or `limit` passed;
    /// removes a downloaded original that waits in the save panel or is being saved.
    public func cancelDocumentDownload(waitingAtMost limit: Duration) async {
        cancelDownload()
        let deadline = ContinuousClock.now + limit
        while runningDownloads > 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Runs `export` with "Saving…" in the banner, then shows its summary or error.
    private func finishExport(title: String, failure: String, _ export: () async throws -> ExportResult) async {
        savingText = "Saving…"
        let alert = NSAlert()
        do {
            let result = try await export()
            alert.messageText = title
            alert.informativeText = result.summary
        } catch {
            alert.alertStyle = .warning
            alert.messageText = failure
            alert.informativeText = error.localizedDescription
        }
        savingText = nil
        exportTask = nil
        send(.saveFinished)
        // Cancelled because the app is quitting: no message.
        guard !Task.isCancelled else { return }
        await show(alert)
    }

    // MARK: Dialogs

    /// What the save panel asks for.
    struct SaveRequest {
        var title: String
        var message: String
        var name: String
        var kind: ExportSaveKind
        /// A document's type, which its Original checkbox names.
        var original: DocumentKind?
    }

    struct SaveChoice {
        var folder: URL
        var formats: Set<ExportFormat>
    }

    /// The save panel, as a sheet on the browser window; nil when cancelled (or there is no window).
    private func chooseSave(_ request: SaveRequest) async -> SaveChoice? {
        if let savePanelOverride { return await savePanelOverride(request) }
        guard let window = webView.window else { return nil }
        let panel = NSSavePanel()
        panel.title = request.title
        panel.message = request.message
        panel.nameFieldStringValue = request.name
        if let initialSaveDirectory { panel.directoryURL = initialSaveDirectory }
        panel.canCreateDirectories = true
        let chooser = FormatChooser(selection: ExportFormatPreference.load(from: defaults, kind: request.kind),
                                    kind: request.kind, original: request.original)
        panel.accessoryView = chooser.view
        let response = await panel.beginSheetModal(for: window)
        // Remembered even when the panel is cancelled.
        let formats = chooser.selection
        ExportFormatPreference.save(formats, to: defaults, kind: request.kind)
        guard response == .OK, let folder = panel.url else { return nil }
        return SaveChoice(folder: folder, formats: formats)
    }

    private func show(_ alert: NSAlert) async {
        if let messageOverride { return messageOverride(alert) }
        guard let window = webView.window else { return }
        _ = await alert.beginSheetModal(for: window)
    }

    // MARK: Document download

    private func startDownload(_ source: DocumentSource) {
        let referer = webView.url
        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        let configuration = documentSessionConfiguration
        let temporaryRoot = documentTemporaryRoot
        runningDownloads += 1
        documentDownload = Task {
            defer { runningDownloads -= 1 }
            let cookies = await cookieStore.allCookies()
            do {
                let document = try await DocumentDownloader.download(source, referer: referer, cookies: cookies,
                                                                     configuration: configuration,
                                                                     temporaryRoot: temporaryRoot)
                guard !Task.isCancelled else { return document.discard() }
                documentDownload = nil
                downloaded = document
                send(.documentDownloaded)
            } catch {
                // Cancelled: the flow has moved on, and the downloader removed its file.
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                documentDownload = nil
                send(.documentUnavailable(error as? DocumentDownloadError ?? .failed(error.localizedDescription)))
            }
        }
    }

    private func cancelDownload() {
        documentDownload?.cancel()
        documentDownload = nil
        downloaded?.discard()
        downloaded = nil
    }

    private func discard(_ document: DownloadedDocument) {
        document.discard()
        if downloaded == document { downloaded = nil }
    }

    // MARK: Effects

    private func perform(_ effect: CaptureEffect) {
        switch effect {
        case .beginPicking:
            bridge.setPicking(true)
        case .endPicking:
            bridge.setPicking(false)
        case .beginCollection(let target):
            let generation = collectionGeneration
            Task { await collect(target, generation: generation) }
        case .stopCollection:
            bridge.stopCollection()
        case .abortCollection:
            collectionGeneration += 1
            collected = nil
            bridge.abortCollection()
        case .presentSave:
            if let collected {
                self.collected = nil
                didFinishCapture(collected)
            }
        case .downloadDocument(let source):
            startDownload(source)
        case .cancelDocumentDownload:
            cancelDownload()
        case .presentDocumentSave:
            // Still tracked while the panel is open, so quitting removes it.
            if let downloaded { saveDocument(downloaded) }
        }
    }

    private func collect(_ target: CaptureTarget, generation: Int) async {
        guard generation == collectionGeneration else { return }
        do {
            let content = try await bridge.collect(target)
            guard generation == collectionGeneration else { return }
            collected = content
            send(.collectionEnded)
        } catch {
            guard generation == collectionGeneration else { return }
            send(.collectionFailed)
            let alert = NSAlert(error: error)
            alert.messageText = "The capture failed."
            alert.runModal()
        }
    }

    // MARK: Keys

    /// ⌘⇧S (any state), and Esc / Return while picking, wherever focus is; see `KeyCommand`.
    /// Returns whether the key was consumed.
    private func handleKey(_ keyCode: UInt16, characters: String?, flags: NSEvent.ModifierFlags) -> Bool {
        guard let event = KeyCommand.event(keyCode: keyCode, characters: characters, flags: flags, phase: machine.phase)
        else { return false }
        send(event)
        return true
    }
}

/// Reports main-frame navigations that commit, which end a capture in progress, and the main
/// frame's responses, whose MIME type says whether the page is itself a document.
private final class NavigationDelegate: NSObject, WKNavigationDelegate {
    var onCommit: (@MainActor () -> Void)?
    var onMainFrameResponse: (@MainActor (URLResponse) -> Void)?

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        onCommit?()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame { onMainFrameResponse?(navigationResponse.response) }
        // What WebKit decides when the delegate does not implement this method.
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .cancel)
    }
}

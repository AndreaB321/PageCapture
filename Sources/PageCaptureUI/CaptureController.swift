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
        }
    }

    public var shortcutEnabled: Bool {
        switch machine.phase {
        case .idle, .picking, .capturing, .stopping: true
        case .saving: false
        }
    }

    public func send(_ event: CaptureEvent) {
        for effect in machine.handle(event) {
            perform(effect)
        }
    }

    /// Saves the capture: save panel (with the format checkboxes), then the export pipeline, then a
    /// message with where it went.
    func didFinishCapture(_ content: CapturedContent) {
        guard let window = webView.window else {
            send(.saveFinished)
            return
        }
        let panel = NSSavePanel()
        panel.title = "Save Capture"
        panel.message = "Creates a folder with the files and an images folder."
        panel.nameFieldStringValue = ExportNaming.sanitizedName(fromTitle: content.title)
        if let initialSaveDirectory { panel.directoryURL = initialSaveDirectory }
        panel.canCreateDirectories = true
        let chooser = FormatChooser(selection: ExportFormatPreference.load(from: defaults))
        panel.accessoryView = chooser.view

        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Remembered even when the panel is cancelled.
                let formats = chooser.selection
                ExportFormatPreference.save(formats, to: self.defaults)
                guard response == .OK, let folder = panel.url else {
                    self.send(.saveFinished)
                    return
                }
                self.exportTask = Task { await self.export(content, formats: formats, to: folder, window: window) }
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

    private func export(_ content: CapturedContent, formats: Set<ExportFormat>, to folder: URL,
                        window: NSWindow) async {
        savingText = "Saving…"
        let alert = NSAlert()
        do {
            let result = try await CaptureExporter.export(content, formats: formats, to: folder) {
                let configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = self.webView.configuration.websiteDataStore
                return configuration
            }
            alert.messageText = "Capture saved"
            alert.informativeText = result.summary
        } catch {
            alert.alertStyle = .warning
            alert.messageText = "The capture could not be saved."
            alert.informativeText = error.localizedDescription
        }
        savingText = nil
        exportTask = nil
        send(.saveFinished)
        // Cancelled because the app is quitting: no message.
        guard !Task.isCancelled else { return }
        _ = await alert.beginSheetModal(for: window)
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

/// Reports main-frame navigations that commit, which end a capture in progress.
private final class NavigationDelegate: NSObject, WKNavigationDelegate {
    var onCommit: (@MainActor () -> Void)?

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        onCommit?()
    }
}

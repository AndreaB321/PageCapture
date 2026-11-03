import AppKit
import Observation
import PageCaptureCore

/// Runs **Update Download Tools**: yt-dlp's own updater, then an alert with the result.
@MainActor
@Observable
public final class ToolsUpdater {
    /// While true the menu item is disabled.
    public private(set) var isRunning = false
    @ObservationIgnored private let tools = Tools()

    public init() {}

    public func update() {
        guard !isRunning else { return }
        isRunning = true
        Task {
            let update = await DownloadToolsUpdate.run(with: tools)
            isRunning = false
            let alert = NSAlert()
            alert.alertStyle = update.succeeded ? .informational : .warning
            alert.messageText = update.title
            alert.informativeText = update.message
            if let window = NSApp.keyWindow ?? NSApp.mainWindow {
                _ = await alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
        }
    }
}

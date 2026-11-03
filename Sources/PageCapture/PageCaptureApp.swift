import AppKit
import PageCaptureCore
import PageCaptureUI
import SwiftUI

@main
struct PageCaptureApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private var controller: CaptureController { appDelegate.controller }
    @State private var toolsUpdater = ToolsUpdater()

    var body: some Scene {
        Window("PageCapture", id: "browser") {
            BrowserView(controller: controller)
                .frame(minWidth: 640, minHeight: 480)
        }
        .defaultSize(width: 1200, height: 900)
        .commands {
            CommandGroup(after: .appSettings) {
                Button("Update Download Tools") { toolsUpdater.update() }
                    .disabled(toolsUpdater.isRunning)
            }
            CommandMenu("Capture") {
                Button(controller.shortcutTitle) { controller.send(.shortcut) }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(!controller.shortcutEnabled)
            }
            CommandGroup(replacing: .help) {
                Button("PageCapture Manual") { ManualWindowController.shared.show() }
                    .keyboardShortcut("?", modifiers: .command)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Here rather than in the App, so quitting can stop its export.
    let controller = CaptureController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // What a crash or a forced quit left behind.
        VideoDownloader.removeTemporaryFiles()
        // Also makes `swift run` behave like the bundled app: Dock icon, menu bar, key window.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    /// Quitting during an export cancels it: the tools are stopped and the temporary files removed
    /// before the app goes, within about 5 s.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard controller.isExporting else { return .terminateNow }
        Task {
            await controller.cancelExport(waitingAtMost: .seconds(3))
            Tools.stopAllRunning()
            VideoDownloader.removeTemporaryFiles()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Backstop: tools lead their own process groups, so they would outlive the app.
    func applicationWillTerminate(_ notification: Notification) {
        Tools.stopAllRunning()
        VideoDownloader.removeTemporaryFiles()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

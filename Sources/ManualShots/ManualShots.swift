// Takes the user manual's screenshots (docs/manual/images) from the real UI: `swift run ManualShots`.
//
// Drives BrowserView and CaptureController in-process, with a non-persistent web data store and its
// own defaults suite, so the installed app's data is left alone. No keystrokes are injected and no
// other app is touched: the capture flow gets the same events ⌘⇧S and the mouse send. Screenshots are
// of this process's own windows only, through ScreenCaptureKit (needs Screen Recording permission
// for the app that runs it, e.g. the terminal).

@preconcurrency import ScreenCaptureKit
import AppKit
import PageCaptureCore
import PageCaptureUI
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// The repository: three levels up from Sources/ManualShots/main.swift.
let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let outputFolder = repository.appendingPathComponent("docs/manual/images", isDirectory: true)
let articleURL = URL(string: "https://en.wikipedia.org/wiki/The_Matrix")!
let windowSize = NSSize(width: 1280, height: 860)
let maxImageWidth = 1600
let defaultsSuite = "local.pagecapture.ManualShots"

struct ShotError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("ManualShots: \(message)\n".utf8))
}

@MainActor
final class Shots: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var controller: CaptureController!
    private let defaults = UserDefaults(suiteName: defaultsSuite)!
    /// A neutral folder, so the screenshots show no user name in the save path.
    private let saveFolder = URL(fileURLWithPath: "/Users/Shared/Captures", isDirectory: true)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        Task {
            try? await Task.sleep(for: .seconds(240))
            self.finish(ShotError("timed out"))
        }
        Task {
            do {
                try await run()
                finish(nil)
            } catch {
                finish(error)
            }
        }
    }

    private func finish(_ error: Error?) {
        if let sheet = window?.attachedSheet { window.endSheet(sheet) }
        try? FileManager.default.removeItem(at: saveFolder)
        defaults.removePersistentDomain(forName: defaultsSuite)
        if let error {
            log("failed: \(error)")
            exit(1)
        }
        log("done: \(outputFolder.path)")
        NSApp.terminate(nil)
    }

    // MARK: The shots

    private func run() async throws {
        prepareImages()
        defaults.removePersistentDomain(forName: defaultsSuite)
        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: saveFolder, withIntermediateDirectories: true)

        controller = CaptureController(dataStore: .nonPersistent(), defaults: defaults)
        controller.initialSaveDirectory = saveFolder
        window = NSWindow(contentRect: NSRect(origin: .zero, size: windowSize),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "PageCapture"
        window.isReleasedWhenClosed = false
        showBrowser(withCredit: false)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()

        log("loading \(articleURL)")
        controller.webView.load(URLRequest(url: articleURL))
        try await waitUntil("the article loaded", timeout: 60) {
            !self.controller.webView.isLoading && self.controller.webView.estimatedProgress >= 1
        }
        try await pause(2.5)
        try await shot("01-window")

        // The launch credit, over the loaded article.
        showBrowser(withCredit: true)
        try await pause(1)
        try await shot("02-credit")
        showBrowser(withCredit: false)
        try await pause(0.5)

        // Picker mode, the pointer over the article.
        controller.send(.shortcut)
        guard controller.machine.phase == .picking else { throw ShotError("⌘⇧S did not start picking") }
        let point = try await articlePoint()
        try await hover(at: point)
        try await pause(0.6)
        try await shot("03-picking")

        // Click the article: the capture starts.
        try await click(at: point)
        try await pause(1.2)
        try await shot("04-capturing")

        // Stop early (⌘⇧S again): the save panel.
        controller.send(.shortcut)
        try await waitUntil("the save panel", timeout: 60) { self.window.attachedSheet is NSSavePanel }
        let panel = window.attachedSheet as! NSSavePanel
        try await pause(1.2)
        guard panel.url?.path.hasPrefix(saveFolder.path) == true else {
            throw ShotError("the save panel did not switch to \(saveFolder.path): \(panel.url?.path ?? "nil")")
        }
        try await shot("05-save-panel", including: panel)

        // Save into that folder. Ending the sheet with OK, as the Save button does; the panel's own
        // ok(_:) never returns when called from here.
        window.endSheet(panel, returnCode: .OK)
        try await waitUntil("the result message", timeout: 180) {
            if let sheet = self.window.attachedSheet { return !(sheet is NSSavePanel) }
            return false
        }
        try await pause(1)
        let alert = window.attachedSheet!
        let texts = labels(in: alert.contentView)
        guard texts.contains("Capture saved") else { throw ShotError("the capture was not saved: \(texts)") }
        try await shot("06-saved", including: alert)
        window.endSheet(alert)
        window.close()
    }

    /// A fresh BrowserView, so the credit's state starts over; the controller and its web view stay.
    private func showBrowser(withCredit credit: Bool) {
        window.contentView = NSHostingView(rootView: BrowserView(controller: controller, showsCredit: credit)
            .frame(minWidth: 640, minHeight: 480))
    }

    /// The bundled app's icon and header avatar, which `swift run` has no bundle for.
    private func prepareImages() {
        NSApp.applicationIconImage = NSImage(contentsOf: repository.appendingPathComponent("Assets/AppIcon.icns"))
        // HeaderBar reads it from the main bundle's resources: the build folder here.
        if let resources = Bundle.main.resourceURL {
            let avatar = resources.appendingPathComponent("header-avatar.png")
            if !FileManager.default.fileExists(atPath: avatar.path) {
                try? FileManager.default.copyItem(at: repository.appendingPathComponent("Assets/header-avatar.png"),
                                                  to: avatar)
            }
        }
    }

    // MARK: Pointer

    /// A point in the article's text, in page (CSS) coordinates.
    private func articlePoint() async throws -> CGPoint {
        let value = try await controller.webView.evaluateJavaScript("""
            (() => {
              const main = document.querySelector('main');
              if (!main) return null;
              const r = main.getBoundingClientRect();
              return [r.left + r.width * 0.4, Math.min(Math.max(r.top, 0) + 320, innerHeight - 80)];
            })()
            """)
        guard let xy = value as? [Double], xy.count == 2 else { throw ShotError("the page has no <main>") }
        return CGPoint(x: xy[0], y: xy[1])
    }

    private func windowPoint(_ pagePoint: CGPoint) -> NSPoint {
        controller.webView.convert(pagePoint, to: nil)
    }

    private func mouseEvent(_ type: NSEvent.EventType, at pagePoint: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: windowPoint(pagePoint), modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                           context: nil, eventNumber: 0, clickCount: type == .mouseMoved ? 0 : 1,
                           pressure: type == .leftMouseDown ? 1 : 0)!
    }

    private func isHighlighted() async throws -> Bool {
        let value = try await controller.webView.evaluateJavaScript("""
            (() => {
              const o = document.querySelector('[data-pagecapture-ui]');
              return !!o && o.style.display === 'block';
            })()
            """)
        return value as? Bool ?? false
    }

    /// Moves the pointer there: a synthetic mouse-moved event to the window, else a `mousemove` in the page.
    private func hover(at point: CGPoint) async throws {
        window.sendEvent(mouseEvent(.mouseMoved, at: point))
        if (try? await waitUntil("the highlight", timeout: 1.5, isHighlighted)) != nil {
            log("hover: window.sendEvent(.mouseMoved)")
            return
        }
        _ = try await controller.webView.evaluateJavaScript("""
            (() => {
              const x = \(point.x), y = \(point.y);
              document.elementFromPoint(x, y).dispatchEvent(new MouseEvent('mousemove',
                { bubbles: true, clientX: x, clientY: y, view: window }));
            })()
            """)
        try await waitUntil("the highlight", timeout: 2, isHighlighted)
        log("hover: mousemove dispatched in the page")
    }

    /// Clicks there: synthetic mouse down and up to the window, else a `click` in the page.
    private func click(at point: CGPoint) async throws {
        window.sendEvent(mouseEvent(.leftMouseDown, at: point))
        window.sendEvent(mouseEvent(.leftMouseUp, at: point))
        if (try? await waitUntil("the capture", timeout: 1.5) { self.isCapturing }) != nil {
            log("click: window.sendEvent(.leftMouseDown/Up)")
            return
        }
        _ = try await controller.webView.evaluateJavaScript("""
            (() => {
              const x = \(point.x), y = \(point.y);
              document.elementFromPoint(x, y).dispatchEvent(new MouseEvent('click',
                { bubbles: true, cancelable: true, clientX: x, clientY: y, view: window }));
            })()
            """)
        try await waitUntil("the capture", timeout: 2) { self.isCapturing }
        log("click: click dispatched in the page")
    }

    private var isCapturing: Bool {
        if case .capturing = controller.machine.phase { return true }
        return false
    }

    // MARK: Screenshots

    /// The window (and `sheet`, when given) as a PNG in docs/manual/images, at most `maxImageWidth` wide.
    private func shot(_ name: String, including sheet: NSWindow? = nil) async throws {
        let wanted = [window, sheet].compactMap { $0 }.map { CGWindowID($0.windowNumber) }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let windows = content.windows.filter { wanted.contains($0.windowID) }
        guard windows.contains(where: { $0.windowID == wanted[0] }) else {
            throw ShotError("\(name): the window is not on screen")
        }
        if windows.count < wanted.count { log("\(name): the sheet is not listed on its own; the window only") }
        let area = windows.map(\.frame).reduce(windows[0].frame) { $0.union($1) }
        guard let display = content.displays.first(where: { $0.frame.intersects(area) }) else {
            throw ShotError("\(name): no display")
        }
        let scale = window.backingScaleFactor
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = area.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        configuration.width = Int(area.width * scale)
        configuration.height = Int(area.height * scale)
        configuration.showsCursor = false
        configuration.backgroundColor = .clear
        configuration.colorSpaceName = CGColorSpace.sRGB
        let filter = SCContentFilter(display: display, including: windows)
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        try writePNG(downscaled(image), to: outputFolder.appendingPathComponent("\(name).png"))
        log("\(name).png")
    }

    private func downscaled(_ image: CGImage) -> CGImage {
        guard image.width > maxImageWidth else { return image }
        let width = maxImageWidth
        let height = Int((Double(image.height) * Double(width) / Double(image.width)).rounded())
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw ShotError("cannot write \(url.path)") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ShotError("cannot write \(url.path)") }
    }

    // MARK: Helpers

    private func labels(in view: NSView?) -> [String] {
        guard let view else { return [] }
        let own = (view as? NSTextField).map { [$0.stringValue] } ?? []
        return own + view.subviews.flatMap { labels(in: $0) }
    }

    private func pause(_ seconds: Double) async throws {
        try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    private func waitUntil(_ what: String, timeout: Double,
                           _ condition: @MainActor () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw ShotError("timed out waiting for \(what)")
    }
}

/// SwiftUI's app lifecycle, as in the app: BrowserView's hosting views expect it.
@main
struct ManualShotsApp: App {
    @NSApplicationDelegateAdaptor(Shots.self) private var shots

    var body: some Scene {
        Settings { EmptyView() }
    }
}

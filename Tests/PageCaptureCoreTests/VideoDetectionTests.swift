import WebKit
import XCTest
@testable import PageCaptureCore

/// Captures `Fixtures/videos.html`, which holds one video of each kind the collector must find: a direct
/// file, a stream whose source appears only on play(), a click-to-load player, a YouTube embed, a video
/// inside a cross-origin iframe (`video-frame.html`) and a DRM-protected video.
@MainActor
final class VideoDetectionTests: XCTestCase {
    private var webView: WKWebView!
    private var bridge: PageCaptureBridge!
    private var window: NSWindow!
    private var ruleStore: URL?

    override func tearDown() async throws {
        window?.close()
        if let ruleStore { try? FileManager.default.removeItem(at: ruleStore) }
        try await super.tearDown()
    }

    func testFindsClassifiesAndReplacesEveryVideoInOrder() async throws {
        try await load("videos.html")
        let frame = try XCTUnwrap(bridge.knownFrames.first { $0.securityOrigin.host == "frame.test" })
        // Media keys cannot be set up without a key system: the collector's view of them is mocked.
        _ = try await evaluate("""
            Object.defineProperty(document.getElementById('drm'), 'mediaKeys', { get: () => ({}) }); 'ok'
            """, frame: nil, in: PageCaptureBridge.contentWorld)

        var timing = CollectionTiming()
        timing.settleDelay = 150
        timing.stallDelay = 300
        timing.imageTimeout = 500
        let content = try await bridge.collect(.wholePage, timing: timing)

        let main = "pctest://main.test/"
        let page = main + "videos.html"
        let mainOrigin = try await evaluate("location.origin", frame: nil) ?? "?"
        let frameOrigin = try await evaluate("location.origin", frame: frame) ?? "?"
        XCTAssertEqual(content.videos, [
            CapturedVideo(index: 0, kind: .file, url: main + "media/clip.mp4", pageURL: page, frameOrigin: mainOrigin,
                          posterURL: main + "posters/file.png", title: "File clip"),
            CapturedVideo(index: 1, kind: .hls, url: main + "streams/live.m3u8", pageURL: page,
                          frameOrigin: mainOrigin, title: "Stream clip"),
            CapturedVideo(index: 2, kind: .file, url: main + "media/loaded.mp4", pageURL: page, frameOrigin: mainOrigin,
                          posterURL: main + "posters/player.png", title: "Player clip"),
            CapturedVideo(index: 3, kind: .youtube, url: "https://www.youtube.com/embed/abc123", pageURL: page,
                          frameOrigin: mainOrigin, title: "YouTube clip"),
            CapturedVideo(index: 4, kind: .file, url: "pctest://frame.test/docs/media/inner.mp4",
                          pageURL: "pctest://frame.test/docs/video-frame.html", frameOrigin: frameOrigin,
                          title: "Inner clip"),
            CapturedVideo(index: 5, kind: .drm, url: main + "protected/master.m3u8", pageURL: page,
                          frameOrigin: mainOrigin, title: "Protected film"),
        ])

        let figures = content.html.matches(of: /<figure data-pc-video="(\d+)">/).map { String($0.output.1) }
        XCTAssertEqual(figures, ["0", "1", "2", "3", "4", "5"], content.html)
        XCTAssertTrue(content.html.contains(
            #"<figure data-pc-video="0"><img src="\#(main)posters/file.png" alt="File clip"><figcaption>Video: File clip</figcaption></figure>"#),
            content.html)
        XCTAssertTrue(content.html.contains(
            #"<figure data-pc-video="1"><figcaption>Video: Stream clip</figcaption></figure>"#), content.html)
        for gone in ["<video", "<iframe", "pc-video ", "<pc-video", "data-pc-frame", "vjs-big-play-button"] {
            XCTAssertFalse(content.html.contains(gone), "\(gone) left in \(content.html)")
        }
        XCTAssertTrue(content.html.contains("Before the videos.") && content.html.contains("After the videos."))
        XCTAssertEqual(content.imageURLs, [main + "posters/file.png", main + "posters/player.png"])

        let paused = "String(Array.from(document.querySelectorAll('video')).map((v) => v.paused))"
        let mainPaused = try await evaluate(paused, frame: nil)
        XCTAssertEqual(mainPaused, "true,true,true,true", "file, stream, player and DRM videos are paused")
        let loaded = try await evaluate(
            "const v = document.getElementById('loaded'); String(v ? [v.paused, v.muted, v.currentTime] : 'missing')",
            frame: nil)
        XCTAssertEqual(loaded, "true,false,0", "the click-to-load video is paused, rewound and not left muted")
        let wrongClicks = try await evaluate("JSON.stringify(window.wrongClicks)", frame: nil)
        XCTAssertEqual(wrongClicks, "[]", "Playback speed, Add to playlist, Display settings and a toggle are not play buttons")
        let framePaused = try await evaluate(paused, frame: frame)
        XCTAssertEqual(framePaused, "true")
        let path = try await evaluate("location.pathname", frame: nil)
        XCTAssertEqual(path, "/videos.html", "the page did not navigate")
    }

    // MARK: Helpers

    /// Loads a fixture from `pctest://main.test/`, with every http(s) load blocked so the YouTube
    /// embed stays offline.
    private func load(_ page: String) async throws {
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(FixtureSchemeHandler(), forURLScheme: FixtureSchemeHandler.scheme)
        let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("VideoRules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true)
        ruleStore = storeURL
        let rules = try await WKContentRuleListStore(url: storeURL).compileContentRuleList(
            forIdentifier: "offline",
            encodedContentRuleList: #"[{"trigger":{"url-filter":"^https?:"},"action":{"type":"block"}}]"#)
        configuration.userContentController.add(try XCTUnwrap(rules))
        bridge = PageCaptureBridge()
        bridge.install(in: configuration)
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        bridge.webView = webView
        window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.orderFrontRegardless()
        webView.load(URLRequest(url: URL(string: "pctest://main.test/\(page)")!))

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let frame = bridge.knownFrames.first(where: { $0.securityOrigin.host == "frame.test" }),
               bridge.knownFrames.contains(where: \.isMainFrame),
               try await evaluate("document.readyState", frame: nil) == "complete",
               try await evaluate("document.readyState", frame: frame) == "complete" {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Timed out loading \(page)")
        throw CancellationError()
    }

    private func evaluate(_ script: String, frame: WKFrameInfo?, in world: WKContentWorld = .page) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script, in: frame, in: world) { result in
                switch result {
                case .success(let value): continuation.resume(returning: value as? String)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
    }
}

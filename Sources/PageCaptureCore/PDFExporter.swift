import AppKit
import PDFKit
import UniformTypeIdentifiers
import WebKit

/// Renders a capture "like the page" and prints it to a paginated PDF (selectable text, live links).
@MainActor
public enum PDFExporter {
    public enum Failure: Error, Equatable {
        case printFailed
    }

    /// Page margin on every side, in points.
    static let margin: CGFloat = 36

    /// Print scale: CSS px print at 72/96 pt times this, so 16 px body text prints at 10 pt rather
    /// than 12 pt, which reads as oversized on A4.
    static let scale: CGFloat = 10.0 / 12.0

    /// The printable area in CSS px (1/96 in; a point is 1/72 in) at `scale`: the paper less the
    /// margins. The document is laid out this wide, so it prints at `scale` times its CSS sizes and
    /// its narrow (responsive) layout applies.
    static func printableSize(_ paperSize: PaperSize) -> CGSize {
        CGSize(width: ((paperSize.points.width - 2 * margin) * 96 / 72 / scale).rounded(.down),
               height: ((paperSize.points.height - 2 * margin) * 96 / 72 / scale).rounded(.down))
    }

    /// `document.js`'s `page` option.
    static func scriptPage(_ paperSize: PaperSize) -> [String: Double] {
        let printable = printableSize(paperSize)
        return ["width": printable.width, "height": printable.height, "paperWidth": paperSize.points.width,
                "paperHeight": paperSize.points.height, "margin": margin]
    }

    /// Longest wait for stylesheets, images and fonts before printing anyway.
    static let resourceTimeout: Duration = .seconds(30)

    /// Writes the PDF for `content` to `url`.
    /// - Parameters:
    ///   - localImages: absolute image URL → downloaded file; those images are embedded from disk.
    ///   - configuration: web view configuration whose website data store (cookies) loads stylesheets
    ///     and remaining images.
    ///   - videos: `data-pc-video` index → how that video's figure appears: its preview image under a
    ///     play button and its caption, one link to the video. Their relative paths are in the
    ///     folder `url` is written to.
    ///   - wrapsInAncestors: wraps the content in the target's element and ancestors as the HTML file
    ///     does (`HTMLExporter`). Off: the PDF is laid out from the content alone.
    public static func write(
        _ content: CapturedContent,
        localImages: [String: URL],
        to url: URL,
        configuration: WKWebViewConfiguration,
        paperSize: PaperSize = .current,
        videos: [Int: VideoLink] = [:],
        wrapsInAncestors: Bool = false
    ) async throws {
        let folder = url.deletingLastPathComponent()
        // A copy, so the browser's own configuration keeps page JavaScript on.
        let configuration = configuration.copy() as! WKWebViewConfiguration
        configuration.preferences.shouldPrintBackgrounds = true
        // The captured page's own scripts (inline handlers, srcdoc iframes) must not run in the
        // renderer; the exporter's injected scripts still do.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = OffscreenWebView(configuration: configuration,
                                    size: printableSize(paperSize))
        defer { view.close() }

        try await view.load(html: "<!doctype html><html><head></head><body></body></html>", baseURL: content.baseURL)
        try await view.run(CaptureScripts.document)
        let sheets: [[String: String]] = content.stylesheets.map {
            switch $0 {
            case .link(let href): ["href": href.absoluteString]
            case .inline(let css): ["css": css]
            }
        }
        _ = try await view.call(
            "PageCaptureDocument.build(options); return 0;",
            arguments: ["options": [
                "html": content.html,
                "title": content.title,
                "baseURL": content.baseURL.absoluteString,
                "sheets": sheets,
                "images": dataURLs(for: localImages),
                "videos": scriptVideos(videos, folder: folder),
                "page": scriptPage(paperSize),
            ]],
            as: Int.self
        )
        try await waitForResources(in: view)
        if wrapsInAncestors {
            // After the stylesheets have loaded: wrap() reads the shells' computed placement.
            _ = try await view.call("PageCaptureDocument.wrap(shells); return 0;",
                                    arguments: ["shells": HTMLExporter.scriptShells(content.ancestors)], as: Int.self)
        }
        _ = try await view.call("PageCaptureDocument.settle(page); return 0;",
                                arguments: ["page": scriptPage(paperSize)], as: Int.self)
        try await print(view.webView, to: url, paperSize: paperSize)
        if !videos.isEmpty {
            try linkVideos(in: url, to: videos.compactMapValues { linkTarget(of: $0, folder: folder) })
        }
    }

    // MARK: Videos

    /// Host of the placeholder links videos are printed with, replaced in the finished PDF: the
    /// document's `<base>` is the remote page, which a relative `videos/…` link would resolve against.
    static let videoMarkerHost = "pagecapture.invalid"

    static func videoMarker(_ index: Int) -> String {
        "https://\(videoMarkerHost)/video/\(index)"
    }

    /// `document.js`'s `videos` option: placeholder links, and previews embedded like local images.
    static func scriptVideos(_ videos: [Int: VideoLink], folder: URL) -> [String: [String: String]] {
        var out: [String: [String: String]] = [:]
        for (index, video) in videos {
            var entry = ["href": videoMarker(index), "title": video.title]
            entry["poster"] = video.posterFile.flatMap { dataURL(for: folder.appendingPathComponent($0)) }
            entry["note"] = video.note
            out[String(index)] = entry
        }
        return out
    }

    /// Where a video's link points in the PDF: a saved video as an absolute `file:` URL, the others
    /// their original URL. PDFKit writes a relative URI, but neither PDFKit nor macOS resolves it
    /// against the PDF's location (it reaches the click handler as a scheme-less URL nothing opens),
    /// so the link breaks if the folder moves.
    static func linkTarget(of video: VideoLink, folder: URL) -> URL? {
        video.isLocal ? folder.appendingPathComponent(video.href) : URL(string: video.href)
    }

    /// Points the printed placeholder links at `targets` (by video index); a placeholder without a
    /// target loses its link.
    static func linkVideos(in url: URL, to targets: [Int: URL]) throws {
        // Read into memory: the PDF is written back over the same file.
        guard let pdf = PDFDocument(data: try Data(contentsOf: url)) else { throw Failure.printFailed }
        var changed = false
        for pageIndex in 0..<pdf.pageCount {
            guard let page = pdf.page(at: pageIndex) else { continue }
            for annotation in page.annotations {
                guard let link = annotation.url, link.host == videoMarkerHost else { continue }
                changed = true
                if let index = Int(link.lastPathComponent), let target = targets[index] {
                    annotation.action = PDFActionURL(url: target)
                } else {
                    page.removeAnnotation(annotation)
                }
            }
        }
        guard changed else { return }
        guard let data = pdf.dataRepresentation() else { throw Failure.printFailed }
        try data.write(to: url, options: .atomic)
    }

    /// Embeds local images as `data:` URLs: the document has the page's origin, which cannot load `file:`.
    static func dataURLs(for localImages: [String: URL]) -> [String: String] {
        var out: [String: String] = [:]
        for (remote, file) in localImages {
            out[remote] = dataURL(for: file)
        }
        return out
    }

    static func dataURL(for file: URL) -> String? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }

    /// Polls from Swift rather than with JS timers, which hidden web views throttle.
    private static func waitForResources(in view: OffscreenWebView) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + resourceTimeout
        while clock.now < deadline {
            let pending = try await view.call("return PageCaptureDocument.pending();", as: Int.self)
            if pending == 0 { return }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func print(_ webView: WKWebView, to url: URL, paperSize: PaperSize) async throws {
        let info = NSPrintInfo()
        info.paperSize = paperSize.points
        info.orientation = .portrait
        info.topMargin = margin
        info.bottomMargin = margin
        info.leftMargin = margin
        info.rightMargin = margin
        // WebKit shrinks the document (laid out 1/`scale` times the printable width, see
        // `printableSize`) to fit the page, so it prints at `scale` times its CSS sizes; a scaling
        // factor here would shrink it twice.
        info.scalingFactor = 1
        info.horizontalPagination = .clip
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url

        let operation = webView.printOperation(with: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.view?.frame = webView.bounds
        // WKWebView prints asynchronously: `run()` never returns, so run it "modally" for the
        // off-screen window (no panel is shown) and wait for the completion callback.
        guard let window = webView.window else { throw Failure.printFailed }
        let ok = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let completion = PrintCompletion { continuation.resume(returning: $0) }
            operation.runModal(for: window, delegate: completion,
                               didRun: #selector(PrintCompletion.printOperationDidRun(_:success:contextInfo:)),
                               contextInfo: Unmanaged.passRetained(completion).toOpaque())
        }
        guard ok, FileManager.default.fileExists(atPath: url.path) else { throw Failure.printFailed }
    }
}

/// Receives `NSPrintOperation`'s did-run callback. Retained through `contextInfo` until it fires.
private final class PrintCompletion: NSObject {
    private let done: (Bool) -> Void

    init(_ done: @escaping (Bool) -> Void) {
        self.done = done
    }

    @objc func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        if let contextInfo { Unmanaged<PrintCompletion>.fromOpaque(contextInfo).release() }
        done(success)
    }
}

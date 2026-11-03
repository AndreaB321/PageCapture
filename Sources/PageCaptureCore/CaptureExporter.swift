import Foundation
import WebKit

/// What an export wrote.
public struct ExportResult: Equatable, Sendable {
    public var folder: URL
    public var html: URL?
    public var pdf: URL?
    public var markdown: URL?
    /// Images that could not be downloaded; the outputs keep their remote URLs.
    public var failedImages: [String]
    /// Video index → how it appears in the outputs.
    public var videos: [Int: VideoLink] = [:]

    public var savedVideoCount: Int { videos.values.filter { $0.outcome == .saved }.count }
    public var protectedVideoCount: Int { videos.values.filter { $0.outcome == .protected }.count }
    public var failedVideoCount: Int { videos.count - savedVideoCount - protectedVideoCount }

    /// One-line message for the user, e.g.
    /// "Saved to … (3 videos saved, 1 protected (linked), 1 failed; 1 image could not be downloaded)".
    public var summary: String {
        var notes = [String]()
        var videoNotes = [String]()
        for (count, what) in [(savedVideoCount, "saved"), (protectedVideoCount, "protected (linked)"), (failedVideoCount, "failed")]
        where count > 0 {
            // The first figure names what it counts.
            let noun = videoNotes.isEmpty ? " video\(count == 1 ? "" : "s")" : ""
            videoNotes.append("\(count)\(noun) \(what)")
        }
        if !videoNotes.isEmpty { notes.append(videoNotes.joined(separator: ", ")) }
        if !failedImages.isEmpty {
            let count = failedImages.count
            notes.append("\(count) image\(count == 1 ? "" : "s") could not be downloaded")
        }
        var text = "Saved to \(folder.path)"
        if !notes.isEmpty { text += " (\(notes.joined(separator: "; ")))" }
        return text
    }
}

/// The save pipeline (SPEC "Saving"): `folder/` gets `images/` and `videos/`, then `Name.html`,
/// `Name.md` and/or `Name.pdf`, where `Name` is the folder's name.
@MainActor
public enum CaptureExporter {
    /// - Parameters:
    ///   - formats: what to write; at least one.
    ///   - webViewConfiguration: makes the HTML and PDF renderers' configuration; its website data
    ///     store also supplies the cookies for the image, stylesheet and video downloads.
    ///   - sessionConfiguration: base configuration for image, stylesheet and video downloads.
    ///   - tools: the bundled tools the video downloads use.
    public static func export(
        _ content: CapturedContent,
        formats: Set<ExportFormat>,
        to folder: URL,
        webViewConfiguration: () -> WKWebViewConfiguration,
        sessionConfiguration: URLSessionConfiguration = .ephemeral,
        paperSize: PaperSize = .current,
        tools: Tools = Tools()
    ) async throws -> ExportResult {
        let fileManager = FileManager.default
        let name = folder.lastPathComponent
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let configuration = webViewConfiguration()
        let cookies = content.imageURLs.isEmpty && content.videos.isEmpty && !formats.contains(.html)
            ? [] : await configuration.websiteDataStore.httpCookieStore.allCookies()

        var images = ImageDownloadResult()
        if !content.imageURLs.isEmpty {
            let imagesFolder = folder.appendingPathComponent(ExportNaming.imagesFolder, isDirectory: true)
            try fileManager.createDirectory(at: imagesFolder, withIntermediateDirectories: true)
            images = await ImageDownloader.download(content.imageURLs, into: imagesFolder, referer: content.baseURL,
                                                    cookies: cookies, configuration: sessionConfiguration)
            if images.files.isEmpty { try? fileManager.removeItem(at: imagesFolder) }
        }
        var result = ExportResult(folder: folder, failedImages: images.failed)

        if !content.videos.isEmpty {
            var posters = [Int: String]()
            for video in content.videos {
                if let poster = video.posterURL, let file = images.files[poster] { posters[video.index] = file }
            }
            result.videos = await VideoDownloader.download(
                content.videos, into: folder, posters: posters, cookies: cookies,
                sessionConfiguration: sessionConfiguration, tools: tools)
        }
        let stylesheets = formats.contains(.html)
            ? await StylesheetInliner.inline(content.stylesheets, page: content.baseURL, cookies: cookies,
                                             configuration: sessionConfiguration)
            : []
        // Cancelled (the app is quitting): stop before writing the outputs.
        try Task.checkCancellation()

        let local = Dictionary(uniqueKeysWithValues: images.files.map {
            ($0.key, folder.appendingPathComponent(ExportNaming.relativeImagePath($0.value)))
        })
        if formats.contains(.html) {
            let url = folder.appendingPathComponent("\(name).html")
            try await HTMLExporter.write(content, stylesheets: stylesheets, localImages: local, to: url,
                                         configuration: configuration, videos: result.videos)
            result.html = url
        }
        if formats.contains(.markdown) {
            let markdown = try await MarkdownExporter.markdown(fromHTML: content.html, images: images.relativePaths,
                                                               videos: result.videos)
            let url = folder.appendingPathComponent("\(name).md")
            try Data(markdown.utf8).write(to: url, options: .atomic)
            result.markdown = url
        }
        if formats.contains(.pdf) {
            let url = folder.appendingPathComponent("\(name).pdf")
            try await PDFExporter.write(content, localImages: local, to: url, configuration: configuration,
                                        paperSize: paperSize, videos: result.videos)
            result.pdf = url
        }
        return result
    }
}

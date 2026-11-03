import Foundation

/// How one captured video appears in the outputs (SPEC "Videos"): its `data-pc-video` figure becomes
/// the preview image linking to `href`. Made by the video downloader, read by the exporters.
public struct VideoLink: Equatable, Sendable {
    /// `videos/<file>` (relative to the capture folder) when the video was saved; otherwise the
    /// original URL to link to.
    public var href: String
    /// `images/<file>` (relative to the capture folder) of its preview image, if one was saved.
    public var posterFile: String?
    public var title: String
    public var outcome: Outcome

    public enum Outcome: Equatable, Sendable {
        case saved
        /// DRM-protected: never downloaded.
        case protected
        /// Could not be downloaded or no source was found; the message says why.
        case failed(String)
    }

    public init(href: String, posterFile: String?, title: String, outcome: Outcome) {
        self.href = href
        self.posterFile = posterFile
        self.title = title
        self.outcome = outcome
    }
}

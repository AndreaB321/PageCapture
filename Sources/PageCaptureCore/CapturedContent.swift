import Foundation

/// The content collected from one capture target, ready for the exporters.
public struct CapturedContent: Equatable, Sendable {
    public enum Stylesheet: Equatable, Sendable {
        /// A `<link rel=stylesheet>` resolved to an absolute URL.
        case link(URL)
        /// The text of an inline `<style>` element.
        case inline(String)
    }

    /// HTML fragment: the target's child nodes, merged in order, with absolute URLs.
    public var html: String
    /// Base URL of the document the target lives in.
    public var baseURL: URL
    public var title: String
    /// The target frame's stylesheets in document order.
    public var stylesheets: [Stylesheet]
    /// Absolute image URLs (`<img>` current sources), unique, in document order. Kept as the page's
    /// own strings: they are the keys the exporters match against the `src` attributes in `html`,
    /// and `URL` would re-encode characters such as `|`.
    public var imageURLs: [String]
    /// Videos found in the target, in document order, one per URL. `html` shows each as
    /// `<figure data-pc-video="N">` (N its `index`) holding its poster, if any, and a caption; the
    /// posters are in `imageURLs`.
    public var videos: [CapturedVideo]
    /// The target element and its ancestors, outermost (`<html>`) first, without their content: what
    /// the HTML file wraps `html` in so the site's layout rules match. For a frame document or the
    /// whole page: its `<html>` and `<body>`.
    public var ancestors: [ElementShell]

    public init(html: String, baseURL: URL, title: String, stylesheets: [Stylesheet], imageURLs: [String],
                videos: [CapturedVideo] = [], ancestors: [ElementShell] = []) {
        self.html = html
        self.baseURL = baseURL
        self.title = title
        self.stylesheets = stylesheets
        self.imageURLs = imageURLs
        self.videos = videos
        self.ancestors = ancestors
    }
}

/// An element without its content: its tag and attributes (no event handlers, `javascript:` URLs or
/// `src`/`srcset`/`href`/`poster`).
public struct ElementShell: Codable, Equatable, Sendable {
    public var tag: String
    public var attributes: [String: String]

    public init(tag: String, attributes: [String: String] = [:]) {
        self.tag = tag
        self.attributes = attributes
    }
}

/// A video found during capture: where its media comes from and how it can be saved.
public struct CapturedVideo: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// A direct media file (mp4, webm, mov, m4v).
        case file
        /// An HLS stream: `url` is its `.m3u8` manifest.
        case hls
        /// A DASH stream: `url` is its `.mpd` manifest.
        case dash
        /// A YouTube embed: `url` is the player iframe's address.
        case youtube
        /// A Vimeo embed: `url` is the player iframe's address.
        case vimeo
        /// DRM-protected (media keys or encrypted media); never downloaded.
        case drm
        /// No media or manifest URL recognised; `url` may be the page's own address.
        case unknown
    }

    /// Position in `CapturedContent.videos`, and the `N` of its `data-pc-video` figure.
    public var index: Int
    public var kind: Kind
    /// Absolute URL of the media file, manifest or embed, as the page's own string (never re-encoded).
    public var url: String
    /// Address of the frame the video plays in: the referer for downloading it.
    public var pageURL: String
    /// Origin of that frame (`"null"` for opaque origins).
    public var frameOrigin: String
    /// Absolute URL of its poster (the `poster` attribute or the player's poster image).
    public var posterURL: String?
    public var title: String?

    public init(index: Int, kind: Kind, url: String, pageURL: String, frameOrigin: String,
                posterURL: String? = nil, title: String? = nil) {
        self.index = index
        self.kind = kind
        self.url = url
        self.pageURL = pageURL
        self.frameOrigin = frameOrigin
        self.posterURL = posterURL
        self.title = title
    }
}

extension CapturedContent {
    public enum DecodingError: Error, Equatable {
        case invalidBaseURL(String)
    }

    /// Wire format produced by `capture.js`.
    struct Payload: Decodable {
        struct Sheet: Decodable {
            var href: String?
            var css: String?
        }

        var html: String
        var baseURL: String
        var title: String
        var stylesheets: [Sheet]
        var imageURLs: [String]
        var videos: [CapturedVideo]
        /// Absent from collectors before shells were recorded.
        var ancestors: [ElementShell]?
    }

    /// Decodes the JSON string returned by the in-page collector.
    public init(collectorJSON json: String) throws {
        let payload = try JSONDecoder().decode(Payload.self, from: Data(json.utf8))
        guard let baseURL = URL(string: payload.baseURL) else {
            throw DecodingError.invalidBaseURL(payload.baseURL)
        }
        let sheets: [Stylesheet] = payload.stylesheets.compactMap { sheet in
            if let href = sheet.href { return URL(string: href).map(Stylesheet.link) }
            return sheet.css.map(Stylesheet.inline)
        }
        self.init(
            html: payload.html,
            baseURL: baseURL,
            title: payload.title,
            stylesheets: sheets,
            imageURLs: payload.imageURLs,
            videos: payload.videos,
            ancestors: payload.ancestors ?? []
        )
    }
}

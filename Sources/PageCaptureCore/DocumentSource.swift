import Foundation

/// A file type the app saves as a document (SPEC "Documents"): the ones the bundled MarkItDown reads.
public enum DocumentKind: String, CaseIterable, Sendable {
    case pdf, docx, pptx, xlsx, xls, msg

    /// The extension the original is saved with.
    public var fileExtension: String { rawValue }

    /// The first bytes every file of this kind starts with.
    public var magic: [UInt8] {
        switch self {
        case .pdf: Array("%PDF-".utf8)
        case .docx, .pptx, .xlsx: [0x50, 0x4B, 0x03, 0x04]
        case .xls, .msg: [0xD0, 0xCF, 0x11, 0xE0]
        }
    }

    public init?(fileExtension: String) {
        self.init(rawValue: fileExtension.lowercased())
    }

    /// `mimeType` may carry parameters (`application/pdf; charset=binary`).
    public init?(mimeType: String) {
        let kind: DocumentKind? = switch Self.essence(of: mimeType) {
        case "application/pdf": .pdf
        case "application/vnd.openxmlformats-officedocument.wordprocessingml.document": .docx
        case "application/vnd.openxmlformats-officedocument.presentationml.presentation": .pptx
        case "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": .xlsx
        case "application/vnd.ms-excel": .xls
        case "application/vnd.ms-outlook": .msg
        default: nil
        }
        guard let kind else { return nil }
        self = kind
    }

    /// Document types MarkItDown cannot read, by extension, so a target of that type is reported
    /// instead of being treated as a page.
    static let unsupportedExtensions: Set<String> = ["doc", "ppt", "rtf", "odt", "ods", "odp"]
    static let unsupportedMIMETypes: [String: String] = [
        "application/msword": "doc",
        "application/vnd.ms-powerpoint": "ppt",
        "application/rtf": "rtf",
        "application/vnd.oasis.opendocument.text": "odt",
        "application/vnd.oasis.opendocument.spreadsheet": "ods",
        "application/vnd.oasis.opendocument.presentation": "odp",
    ]

    static func essence(of mimeType: String) -> String {
        mimeType.split(separator: ";", maxSplits: 1).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces).lowercased() ?? ""
    }
}

/// Why the original of a picked document is not saved; the frame is captured as a page instead
/// and the result message gives `reason`.
public enum DocumentDownloadError: Error, Equatable, Sendable {
    /// An online viewer whose URL does not hold the original's http(s) URL.
    case noURLInViewer
    /// A document type MarkItDown cannot read (the extension, e.g. `doc`), or `""` when the
    /// viewer's original has no recognisable type.
    case unsupportedType(String)
    /// The server answered with this status instead of the file.
    case httpStatus(Int)
    /// The response does not start like the document's kind: typically a sign-in page.
    case notADocument
    /// Larger than `DocumentDownloader.maxBytes`.
    case tooLarge
    /// The request itself failed (no connection, timeout, …): the system's description.
    case failed(String)

    /// For the result message, after "the document could not be downloaded (…)". Holds no paths.
    public var reason: String {
        switch self {
        case .noURLInViewer: "the viewer does not give the original's address"
        case .unsupportedType(let ext): ext.isEmpty ? "its file type is not known" : ".\(ext) files are not supported"
        case .httpStatus(let status): "HTTP \(status)"
        case .notADocument: "the site sent a web page, perhaps a sign-in page, instead of the file"
        case .tooLarge: "it is larger than \(DocumentDownloader.maxBytes >> 20) MB"
        case .failed(let message): message
        }
    }
}

/// What a picked target is, when it is a document.
public enum DocumentDetection: Equatable, Sendable {
    /// A supported document whose original can be downloaded.
    case document(DocumentSource)
    /// A document (or a viewer showing one) whose original cannot be saved: capture it as a page
    /// and report why.
    case unavailable(DocumentDownloadError)
}

/// The original file behind a document target (SPEC "Documents").
public struct DocumentSource: Equatable, Sendable {
    /// The original's http(s) URL, query included (signed URLs need it).
    public var url: URL
    public var kind: DocumentKind

    public init(url: URL, kind: DocumentKind) {
        self.url = url
        self.kind = kind
    }

    /// The source behind `url` (a frame's or the page's URL) with its `mimeType` (the document's
    /// `contentType`), or `nil` when it is not a supported document that can be downloaded.
    public init?(url: URL, mimeType: String? = nil) {
        guard case .document(let source) = Self.detect(url: url, mimeType: mimeType) else { return nil }
        self = source
    }

    /// `nil` when `url` is not a document at all (only http(s) URLs can be); otherwise the document
    /// or why it cannot be downloaded. Online viewers are unwrapped to the original they show.
    public static func detect(url: URL, mimeType: String? = nil) -> DocumentDetection? {
        guard isHTTP(url) else { return nil }
        guard let inner = viewedURL(in: url) else { return direct(url, mimeType: mimeType) }
        // A viewer: the original's URL is in its query, perhaps inside a second viewer.
        guard var original = inner else { return .unavailable(.noURLInViewer) }
        if let nested = viewedURL(in: original) {
            guard let nestedOriginal = nested, viewedURL(in: nestedOriginal) == nil else {
                return .unavailable(.noURLInViewer)
            }
            original = nestedOriginal
        }
        // The viewer's MIME type is the viewer page's, so only the original's extension counts.
        return direct(original, mimeType: nil) ?? .unavailable(.unsupportedType(""))
    }

    private static func direct(_ url: URL, mimeType: String?) -> DocumentDetection? {
        let ext = url.pathExtension.lowercased()
        if let kind = DocumentKind(fileExtension: ext) { return .document(DocumentSource(url: url, kind: kind)) }
        if let mimeType, let kind = DocumentKind(mimeType: mimeType) {
            return .document(DocumentSource(url: url, kind: kind))
        }
        if DocumentKind.unsupportedExtensions.contains(ext) { return .unavailable(.unsupportedType(ext)) }
        if let mimeType, let unsupported = DocumentKind.unsupportedMIMETypes[DocumentKind.essence(of: mimeType)] {
            return .unavailable(.unsupportedType(unsupported))
        }
        return nil
    }

    /// The viewers whose URL names the original: host, path, query parameter.
    private static let viewers: [(host: String, paths: Set<String>, parameter: String)] = [
        ("view.officeapps.live.com", ["/op/embed.aspx", "/op/view.aspx"], "src"),
        ("docs.google.com", ["/viewer", "/gview"], "url"),
        ("drive.google.com", ["/viewerng/viewer"], "url"),
    ]

    /// `nil` when `url` is not a viewer; `.some(nil)` when it is one without a usable original URL.
    private static func viewedURL(in url: URL) -> URL?? {
        guard isHTTP(url), let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased(),
              let viewer = viewers.first(where: { $0.host == host && $0.paths.contains(components.path.lowercased()) })
        else { return nil }
        guard var value = components.queryItems?.first(where: { $0.name == viewer.parameter })?.value else {
            return .some(nil)
        }
        // Encoded twice (`https%253A…`): decode the second layer too.
        if !value.contains("://"), let decoded = value.removingPercentEncoding, decoded.contains("://") {
            value = decoded
        }
        guard let original = URL(string: value.trimmingCharacters(in: .whitespaces)), isHTTP(original),
              original.host?.isEmpty == false
        else { return .some(nil) }
        return .some(original)
    }

    private static func isHTTP(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }
}

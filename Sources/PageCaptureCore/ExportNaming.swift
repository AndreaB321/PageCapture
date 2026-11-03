import Foundation
import UniformTypeIdentifiers

/// Pure naming rules for the output folder (SPEC "Saving").
public enum ExportNaming {
    /// Folder name holding the downloaded images, relative to the output folder.
    public static let imagesFolder = "images"
    /// Folder name holding the downloaded videos, relative to the output folder.
    public static let videosFolder = "videos"

    /// A file name derived from a page title: path separators, colons and control characters become
    /// dashes, whitespace is collapsed, leading dots and surrounding spaces/dots are trimmed, and the
    /// result is capped at 100 characters. Falls back to "Capture".
    public static func sanitizedName(fromTitle title: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in title.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                scalars.append(" ")
            } else if scalar == "/" || scalar == ":" || scalar == "\\" || CharacterSet.controlCharacters.contains(scalar) {
                scalars.append("-")
            } else {
                scalars.append(scalar)
            }
        }
        var name = String(scalars)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        name = String(name.prefix(100))
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return name.isEmpty ? "Capture" : name
    }

    /// The file name for the image at `index` (0-based) of `CapturedContent.imageURLs`:
    /// `001-<basename>.<ext>`. The basename comes from the URL's last path component (sanitised,
    /// "image" when there is none, as for `data:` URLs); the extension from the URL when it is an
    /// image extension, else from `mimeType`, else "img".
    public static func imageFileName(index: Int, url: URL, mimeType: String?) -> String {
        let number = String(format: "%03d", index + 1)
        var base = "image"
        var ext: String?
        if url.scheme?.lowercased() != "data" {
            let last = url.lastPathComponent
            let urlExt = (last as NSString).pathExtension.lowercased()
            if isImageExtension(urlExt) {
                ext = urlExt
                base = (last as NSString).deletingPathExtension
            } else if !urlExt.isEmpty, urlExt.count <= 5 {
                base = (last as NSString).deletingPathExtension
            } else {
                base = last
            }
            base = sanitizedBasename(base)
        }
        let finalExt = ext ?? mimeType.flatMap(fileExtension(forMIMEType:)) ?? "img"
        return "\(number)-\(base).\(finalExt)"
    }

    /// Relative path used in Markdown for a downloaded image file.
    public static func relativeImagePath(_ fileName: String) -> String {
        "\(imagesFolder)/\(fileName)"
    }

    /// `001-<name>` for the video at `index` (0-based, `CapturedVideo.index`), without extension.
    /// The name is the title sanitised like a page title (capped at 60 characters, with `#`, `?` and
    /// `%` replaced by `-`: they break Markdown links and yt-dlp output templates), else the URL's last path component sanitised like an
    /// image basename, else "video".
    public static func videoFileStem(index: Int, title: String?, url: String) -> String {
        let number = String(format: "%03d", index + 1)
        var cleanedTitle = title ?? ""
        for char in ["#", "?", "%"] { cleanedTitle = cleanedTitle.replacingOccurrences(of: char, with: "-") }
        cleanedTitle = cleanedTitle
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanedTitle.isEmpty {
            let name = String(sanitizedName(fromTitle: cleanedTitle).prefix(60))
                .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
            if !name.isEmpty { return "\(number)-\(name)" }
        }
        var base = "video"
        if let url = URL(string: url), url.scheme?.lowercased() != "data" {
            base = sanitizedBasename((url.lastPathComponent as NSString).deletingPathExtension, fallback: "video")
        }
        return "\(number)-\(base)"
    }

    /// Relative path used in the outputs for a downloaded video file.
    public static func relativeVideoPath(_ fileName: String) -> String {
        "\(videosFolder)/\(fileName)"
    }

    private static func sanitizedBasename(_ raw: String, fallback: String = "image") -> String {
        let decoded = raw.removingPercentEncoding ?? raw
        var out = ""
        var lastWasDash = false
        for scalar in decoded.unicodeScalars {
            let ok = scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == ".")
            if ok {
                out.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
        }
        out = String(out.trimmingCharacters(in: CharacterSet(charactersIn: "-.")).prefix(60))
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return out.isEmpty || out == "/" ? fallback : out
    }

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "svg", "avif", "bmp", "ico", "tif", "tiff", "heic", "heif", "jxl",
    ]

    private static func isImageExtension(_ ext: String) -> Bool { imageExtensions.contains(ext) }

    static func fileExtension(forMIMEType mime: String) -> String? {
        let type = mime.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        switch type {
        case "image/jpeg", "image/jpg", "image/pjpeg": return "jpg"
        case "image/svg+xml": return "svg"
        case "image/x-icon", "image/vnd.microsoft.icon": return "ico"
        default:
            if let ext = UTType(mimeType: type)?.preferredFilenameExtension { return ext }
            if type.hasPrefix("image/") {
                let sub = type.dropFirst("image/".count)
                if !sub.isEmpty, sub.allSatisfy({ $0.isLetter || $0.isNumber }) { return String(sub) }
            }
            return nil
        }
    }
}

/// `data:` URL decoding (RFC 2397).
public enum DataURL {
    /// The bytes and MIME type of a `data:` URL, or `nil` if it is not a well-formed one.
    public static func decode(_ string: String) -> (data: Data, mimeType: String)? {
        guard string.lowercased().hasPrefix("data:"), let comma = string.firstIndex(of: ",") else { return nil }
        let header = string[string.index(string.startIndex, offsetBy: 5)..<comma]
        let payload = String(string[string.index(after: comma)...])
        var params = header.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        let isBase64 = params.last?.lowercased() == "base64"
        if isBase64 { params.removeLast() }
        let mime = params.first.flatMap { $0.isEmpty ? nil : $0.lowercased() } ?? "text/plain"
        if isBase64 {
            let cleaned = (payload.removingPercentEncoding ?? payload).filter { !$0.isWhitespace }
            var padded = cleaned
            while padded.count % 4 != 0 { padded.append("=") }
            guard let data = Data(base64Encoded: padded) else { return nil }
            return (data, mime)
        }
        guard let text = payload.removingPercentEncoding else { return nil }
        return (Data(text.utf8), mime)
    }
}

/// Paper size for the PDF, chosen by the system locale's region.
public enum PaperSize: Equatable, Sendable {
    case a4
    case letter

    /// Regions that use US Letter; everything else (and an unknown region) gets A4.
    static let letterRegions: Set<String> = [
        "US", "CA", "MX", "PR", "PH", "CL", "CO", "VE", "GT", "CR", "PA", "DO", "SV", "NI", "BZ",
    ]

    public static func forRegion(_ identifier: String?) -> PaperSize {
        guard let identifier else { return .a4 }
        return letterRegions.contains(identifier.uppercased()) ? .letter : .a4
    }

    public static var current: PaperSize { forRegion(Locale.current.region?.identifier) }

    /// Size in PostScript points.
    public var points: CGSize {
        switch self {
        case .a4: CGSize(width: 595.28, height: 841.89)
        case .letter: CGSize(width: 612, height: 792)
        }
    }
}

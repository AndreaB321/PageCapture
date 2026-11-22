import CoreGraphics
import CoreML
import Foundation
import Vision

public enum PDFTextRecognizerError: Error, Equatable {
    /// CoreGraphics cannot open the file, it is locked with a password, or it has no pages.
    case unreadable
    /// OCR found no text on any page.
    case noText
}

/// Reads the text of an image-only (scanned) PDF with Apple's on-device Vision OCR and returns Markdown.
/// Recognition uses `.fast`, because the sandboxed helper has no Neural Engine. It still needs the GPU:
/// the helper's sandbox allows the GPU's user client (`AGXDeviceUserClient`), without which Vision finds
/// no text at all, even in `.fast` mode. `.fast` is less precise than `.accurate` on hard scans and
/// supports fewer languages (the European ones are fine).
public enum PDFTextRecognizer {
    /// Longest side of a rendered page, in pixels (bounds memory).
    static let maxPixelSide: CGFloat = 4000
    static let renderDPI: CGFloat = 300

    /// OCRs up to `maxPages` pages, in order. With more than one page each starts with `<!-- page N -->`;
    /// when pages were left out, the Markdown ends with `<!-- stopped after N of M pages -->`.
    /// Renders with CoreGraphics alone, not PDFKit: PDFKit brings up AppKit, which reaches for the
    /// window server and the Dock, and the OCR helper's sandbox has neither.
    public static func markdown(fromPDF url: URL, maxPages: Int = 300) async throws -> String {
        guard let document = CGPDFDocument(url as CFURL), document.isUnlocked, document.numberOfPages > 0 else {
            throw PDFTextRecognizerError.unreadable
        }
        let pageCount = document.numberOfPages
        let count = min(pageCount, max(maxPages, 0))
        let labelled = pageCount > 1
        var pages: [String] = []
        var recognisedAny = false
        for index in 0..<count {
            if Task.isCancelled { throw CancellationError() }
            let text: String = try autoreleasepool {
                // CGPDFDocument numbers pages from 1.
                guard let page = document.page(at: index + 1), let image = render(page) else { return "" }
                return try recognise(image)
            }
            if !text.isEmpty { recognisedAny = true }
            pages.append(labelled ? "<!-- page \(index + 1) -->\n\n\(text)" : text)
        }
        guard recognisedAny else { throw PDFTextRecognizerError.noText }
        if count < pageCount {
            pages.append("<!-- stopped after \(count) of \(pageCount) pages -->")
        }
        return pages.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n") + "\n"
    }

    // MARK: Rendering

    private static func render(_ page: CGPDFPage) -> CGImage? {
        let box = page.getBoxRect(.cropBox)
        let rotated = page.rotationAngle % 180 != 0
        let pointSize = rotated ? CGSize(width: box.height, height: box.width) : box.size
        guard pointSize.width > 0, pointSize.height > 0 else { return nil }
        let scale = min(renderDPI / 72, maxPixelSide / max(pointSize.width, pointSize.height))
        let width = max(Int((pointSize.width * scale).rounded()), 1)
        let height = max(Int((pointSize.height * scale).rounded()), 1)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: CGFloat(width) / pointSize.width, y: CGFloat(height) / pointSize.height)
        // At the page's own size the transform only rotates the crop box and moves it into place.
        context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: pointSize),
                                                     rotate: 0, preserveAspectRatio: true))
        context.clip(to: box)
        context.drawPDFPage(page)
        return context.makeImage()
    }

    // MARK: Recognition

    private struct Line {
        var text: String
        var box: CGRect  // normalised, origin bottom left
    }

    private static func recognise(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try useCPUOnly(request)
        try VNImageRequestHandler(cgImage: image).perform([request])
        let lines = (request.results ?? []).compactMap { observation -> Line? in
            guard let text = observation.topCandidates(1).first?.string,
                !text.trimmingCharacters(in: .whitespaces).isEmpty
            else { return nil }
            return Line(text: text, box: observation.boundingBox)
        }
        return paragraphs(from: lines)
    }

    /// Asks for every stage of `request` on the CPU, so `.fast` stays off the Neural Engine, which
    /// the OCR helper's sandbox denies (on macOS 27 the `.accurate` detector uses it whatever is
    /// set here). Vision still opens the GPU's user client and finds no text without it, so the
    /// sandbox allows that one.
    private static func useCPUOnly(_ request: VNRequest) throws {
        for (stage, devices) in try request.supportedComputeStageDevices {
            guard let cpu = devices.first(where: { if case .cpu = $0 { true } else { false } }) else { continue }
            request.setComputeDevice(cpu, for: stage)
        }
    }

    /// Orders lines top to bottom then left to right, and starts a new paragraph at a vertical gap
    /// larger than 1.5 times the median line height.
    private static func paragraphs(from lines: [Line]) -> String {
        guard !lines.isEmpty else { return "" }
        let heights = lines.map(\.box.height).sorted()
        let median = heights[heights.count / 2]
        // Group into rows: boxes whose vertical centres are within half a median height share a row.
        var rows: [[Line]] = []
        for line in lines.sorted(by: { $0.box.midY > $1.box.midY }) {
            if let first = rows.last?.first, abs(first.box.midY - line.box.midY) < median / 2 {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        var paragraphs: [[String]] = []
        var previousBottom: CGFloat?
        for row in rows {
            let sorted = row.sorted { $0.box.minX < $1.box.minX }
            let text = sorted.map(\.text).joined(separator: " ")
            let top = sorted.map { $0.box.maxY }.max() ?? 0
            let bottom = sorted.map { $0.box.minY }.min() ?? 0
            if let previousBottom, previousBottom - top <= median * 1.5, !paragraphs.isEmpty {
                paragraphs[paragraphs.count - 1].append(text)
            } else {
                paragraphs.append([text])
            }
            previousBottom = bottom
        }
        return paragraphs.map { escapeLineStart($0.joined(separator: " ")) }.joined(separator: "\n\n")
    }

    /// Stops OCR text from turning into headings, lists, quotes, HTML, table rows or code fences
    /// (a fence would swallow every later page).
    static func escapeLineStart(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return trimmed }
        if "#-*+><|".contains(first) || trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
            return "\\" + trimmed
        }
        let digits = trimmed.prefix { $0.isASCII && $0.isNumber }
        if !digits.isEmpty {
            let rest = trimmed.dropFirst(digits.count)
            if let mark = rest.first, mark == "." || mark == ")" {
                return digits + "\\" + rest
            }
        }
        return trimmed
    }
}

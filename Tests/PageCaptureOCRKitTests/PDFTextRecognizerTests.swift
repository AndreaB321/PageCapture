import AppKit
import CoreText
import Foundation
import Testing

@testable import PageCaptureOCRKit

@Suite struct PDFTextRecognizerTests {
    /// A text block: lines drawn at a y offset from the top of the page (points, 612 x 792).
    struct Block {
        var lines: [String]
        var top: CGFloat
    }

    static let pageSize = CGSize(width: 612, height: 792)
    static var font: NSFont { NSFont.systemFont(ofSize: 22) }

    static func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("pdfocr-\(UUID().uuidString).pdf")
    }

    /// Black text on white, 4x scale bitmap.
    static func bitmap(_ blocks: [Block]) -> CGImage {
        let scale: CGFloat = 4
        let width = Int(pageSize.width * scale), height = Int(pageSize.height * scale)
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.black,
        ]
        for block in blocks {
            for (index, line) in block.lines.enumerated() {
                let y = pageSize.height - block.top - CGFloat(index + 1) * 30
                let ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: attributes))
                context.textPosition = CGPoint(x: 50, y: y)
                CTLineDraw(ctLine, context)
            }
        }
        let img = context.makeImage()!
        return img
    }

    /// PDF whose pages contain only an image, so there is no text layer.
    static func scannedPDF(_ pages: [[Block]]) -> URL {
        let url = tempURL()
        var box = CGRect(origin: .zero, size: pageSize)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        for blocks in pages {
            context.beginPDFPage(nil)
            context.draw(bitmap(blocks), in: box)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    static func textPDF(_ text: String) -> URL {
        let url = tempURL()
        var box = CGRect(origin: .zero, size: pageSize)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        context.textPosition = CGPoint(x: 50, y: 700)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()
        return url
    }

    static func blankPDF() -> URL { scannedPDF([[]]) }

    static func normalised(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
    }

    @Test func recognisesScannedPage() async throws {
        let url = Self.scannedPDF([[Block(lines: ["PageCapture reads scanned pages"], top: 100)]])
        defer { try? FileManager.default.removeItem(at: url) }
        let output = Self.normalised(try await PDFTextRecognizer.markdown(fromPDF: url))
        #expect(output.contains("pagecapture reads scanned pages"))
        #expect(!output.contains("page 1"))
    }

    @Test func twoPagesInOrderWithMarkers() async throws {
        let url = Self.scannedPDF([
            [Block(lines: ["First page alpha"], top: 100)], [Block(lines: ["Second page beta"], top: 100)],
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let output = try await PDFTextRecognizer.markdown(fromPDF: url)
        let marker1 = try #require(output.range(of: "<!-- page 1 -->"))
        let alpha = try #require(output.lowercased().range(of: "alpha"))
        let marker2 = try #require(output.range(of: "<!-- page 2 -->"))
        let beta = try #require(output.lowercased().range(of: "beta"))
        #expect(marker1.upperBound <= alpha.lowerBound)
        #expect(alpha.upperBound <= marker2.lowerBound)
        #expect(marker2.upperBound <= beta.lowerBound)
    }

    @Test func paragraphsSplitOnLargeGapOnly() async throws {
        let url = Self.scannedPDF([[
            Block(lines: ["Alpha one here", "Alpha two here"], top: 80),
            Block(lines: ["Omega far below"], top: 500),
        ]])
        defer { try? FileManager.default.removeItem(at: url) }
        let output = try await PDFTextRecognizer.markdown(fromPDF: url)
        let paragraphs = output.components(separatedBy: "\n\n").filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        try #require(paragraphs.count == 2)
        #expect(paragraphs[0].lowercased().contains("alpha one"))
        #expect(paragraphs[0].lowercased().contains("alpha two"))
        #expect(paragraphs[1].lowercased().contains("omega"))
    }

    @Test func escapesMarkdownLineStarts() async throws {
        let url = Self.scannedPDF([[Block(lines: ["# not a heading"], top: 100)]])
        defer { try? FileManager.default.removeItem(at: url) }
        let output = try await PDFTextRecognizer.markdown(fromPDF: url)
        #expect(output.contains("\\#"))
        #expect(!output.hasPrefix("#"))
        #expect(PDFTextRecognizer.escapeLineStart("1. item") == "1\\. item")
        #expect(PDFTextRecognizer.escapeLineStart("- x") == "\\- x")
        #expect(PDFTextRecognizer.escapeLineStart("> q") == "\\> q")
        #expect(PDFTextRecognizer.escapeLineStart("plain") == "plain")
    }

    /// A fence would swallow every later page; HTML and table rows would not read as text.
    @Test func escapesFencesHTMLAndTableRows() {
        #expect(PDFTextRecognizer.escapeLineStart("```swift") == "\\```swift")
        #expect(PDFTextRecognizer.escapeLineStart("~~~ code") == "\\~~~ code")
        #expect(PDFTextRecognizer.escapeLineStart("<div>") == "\\<div>")
        #expect(PDFTextRecognizer.escapeLineStart("| a | b |") == "\\| a | b |")
        #expect(PDFTextRecognizer.escapeLineStart("a ``` b") == "a ``` b")
    }

    @Test func detectsTextLayer() {
        let scanned = Self.scannedPDF([[Block(lines: ["Scanned only"], top: 100)]])
        let text = Self.textPDF("Real text layer")
        defer {
            try? FileManager.default.removeItem(at: scanned)
            try? FileManager.default.removeItem(at: text)
        }
        #expect(!PDFTextRecognizer.hasTextLayer(scanned))
        #expect(PDFTextRecognizer.hasTextLayer(text))
    }

    @Test func unreadableAndBlank() async throws {
        let junk = Self.tempURL()
        try Data((0..<2048).map { _ in UInt8.random(in: 0...255) }).write(to: junk)
        let blank = Self.blankPDF()
        defer {
            try? FileManager.default.removeItem(at: junk)
            try? FileManager.default.removeItem(at: blank)
        }
        await #expect(throws: PDFTextRecognizerError.unreadable) {
            try await PDFTextRecognizer.markdown(fromPDF: junk)
        }
        await #expect(throws: PDFTextRecognizerError.noText) {
            try await PDFTextRecognizer.markdown(fromPDF: blank)
        }
    }

    @Test func maxPagesLimitsOutput() async throws {
        let url = Self.scannedPDF([
            [Block(lines: ["First page alpha"], top: 100)], [Block(lines: ["Second page beta"], top: 100)],
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let output = try await PDFTextRecognizer.markdown(fromPDF: url, maxPages: 1).lowercased()
        #expect(output.contains("alpha"))
        #expect(!output.contains("beta"))
        #expect(!output.contains("<!-- page 2 -->"))
        #expect(output.hasSuffix("<!-- stopped after 1 of 2 pages -->\n"))
    }

    @Test func noTruncationNoteWhenAllPagesAreRead() async throws {
        let url = Self.scannedPDF([[Block(lines: ["Only page gamma"], top: 100)]])
        defer { try? FileManager.default.removeItem(at: url) }
        let output = try await PDFTextRecognizer.markdown(fromPDF: url, maxPages: 1)
        #expect(!output.contains("stopped after"))
    }
}

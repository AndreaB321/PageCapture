import Foundation
import PageCaptureOCRKit

// pagecapture-ocr <pdf> [--max-pages N]
//
// OCRs a scanned PDF with Vision and writes the Markdown to stdout as UTF-8. `DocumentConverter`
// runs it under `sandbox-exec` (`DocumentConverter.ocrSandboxProfile`), so untrusted PDFs are
// never decoded in the app's own process. Exit status:
//   0  the Markdown is on stdout
//   1  OCR failed otherwise (message on stderr)
//   2  usage error
//   3  unreadable: not a PDF, damaged, locked with a password, or no pages
//   4  no text: OCR found no text on any page
// Messages on stderr are one short line and never name a path.

enum ExitCode {
    static let failed: Int32 = 1
    static let usage: Int32 = 2
    static let unreadable: Int32 = 3
    static let noText: Int32 = 4
}

func fail(_ status: Int32, _ message: String) -> Never {
    FileHandle.standardError.write(Data("pagecapture-ocr: \(message)\n".utf8))
    exit(status)
}

var arguments = Array(CommandLine.arguments.dropFirst())

#if DEBUG
// Test probes, compiled into debug builds only: they show what the sandbox lets the helper do.
if let probe = arguments.first, probe.hasPrefix("--probe-") {
    runProbe(probe, Array(arguments.dropFirst()))
}
#endif

var maxPages = 300
if let index = arguments.firstIndex(of: "--max-pages") {
    guard index + 1 < arguments.count, let value = Int(arguments[index + 1]), value > 0 else {
        fail(ExitCode.usage, "--max-pages needs a positive number")
    }
    maxPages = value
    arguments.removeSubrange(index...index + 1)
}
guard arguments.count == 1, !arguments[0].hasPrefix("-") else {
    fail(ExitCode.usage, "usage: pagecapture-ocr <pdf> [--max-pages N]")
}

do {
    let markdown = try await PDFTextRecognizer.markdown(fromPDF: URL(fileURLWithPath: arguments[0]), maxPages: maxPages)
    FileHandle.standardOutput.write(Data(markdown.utf8))
    exit(0)
} catch PDFTextRecognizerError.unreadable {
    fail(ExitCode.unreadable, "cannot read the PDF (damaged, not a PDF, locked, or no pages)")
} catch PDFTextRecognizerError.noText {
    fail(ExitCode.noText, "no text found")
} catch {
    fail(ExitCode.failed, "text recognition failed (\((error as NSError).domain) \((error as NSError).code))")
}

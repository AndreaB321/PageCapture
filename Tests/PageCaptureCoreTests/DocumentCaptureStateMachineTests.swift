import XCTest
@testable import PageCaptureCore

/// The ⌘⇧S flow for document targets (SPEC "Documents").
final class DocumentCaptureStateMachineTests: XCTestCase {
    private let source = DocumentSource(url: URL(string: "https://example.com/report.pdf")!, kind: .pdf)

    private func machine(after events: CaptureEvent...) -> CaptureStateMachine {
        var machine = CaptureStateMachine()
        for event in events { machine.handle(event) }
        return machine
    }

    func testPickingADocumentDownloadsItWithoutCollecting() {
        var machine = machine(after: .shortcut)
        XCTAssertEqual(machine.handle(.picked(.document(source))), [.endPicking, .downloadDocument(source)])
        XCTAssertEqual(machine.phase, .downloadingDocument(source))
        XCTAssertEqual(machine.bannerText, "Downloading document…")
    }

    func testDownloadedDocumentPresentsTheDocumentSave() {
        var machine = machine(after: .shortcut, .picked(.document(source)))
        XCTAssertEqual(machine.handle(.documentDownloaded), [.presentDocumentSave(source)])
        XCTAssertEqual(machine.phase, .saving)
        XCTAssertNil(machine.bannerText)
        XCTAssertNil(machine.documentFallback)
        XCTAssertEqual(machine.handle(.saveFinished), [])
        XCTAssertEqual(machine.phase, .idle)
    }

    func testUnavailableDocumentFallsBackToCapturingTheFrameAndKeepsTheReason() {
        var machine = machine(after: .shortcut, .picked(.document(source)))
        XCTAssertEqual(machine.handle(.documentUnavailable(.notADocument)), [.beginCollection(.picked)])
        XCTAssertEqual(machine.phase, .capturing(.picked))
        XCTAssertEqual(machine.bannerText, "Capturing…")
        XCTAssertEqual(machine.documentFallback, .notADocument)
        XCTAssertEqual(machine.handle(.collectionEnded), [.presentSave])
        XCTAssertEqual(machine.documentFallback, .notADocument, "kept for the result message")
        machine.handle(.saveFinished)
        XCTAssertNil(machine.documentFallback, "cleared once idle")
    }

    func testDocumentUnavailableWhilePickingCapturesTheFrame() {
        var machine = machine(after: .shortcut)
        XCTAssertEqual(machine.handle(.documentUnavailable(.noURLInViewer)), [.endPicking, .beginCollection(.picked)])
        XCTAssertEqual(machine.phase, .capturing(.picked))
        XCTAssertEqual(machine.documentFallback, .noURLInViewer)
        machine.handle(.collectionFailed)
        XCTAssertNil(machine.documentFallback)
    }

    func testShortcutOrNavigationCancelsTheDownload() {
        for event in [CaptureEvent.shortcut, .navigated] {
            var machine = machine(after: .shortcut, .picked(.document(source)))
            XCTAssertEqual(machine.handle(event), [.cancelDocumentDownload], "\(event)")
            XCTAssertEqual(machine.phase, .idle)
            XCTAssertNil(machine.bannerText)
        }
    }

    func testDocumentEventsOutsideTheirPhaseAreIgnored() {
        for start in [machine(), machine(after: .shortcut, .returnKey), machine(after: .shortcut, .returnKey, .collectionEnded)] {
            for event in [CaptureEvent.documentDownloaded, .documentUnavailable(.tooLarge)] {
                var copy = start
                XCTAssertEqual(copy.handle(event), [], "\(start.phase) \(event)")
                XCTAssertEqual(copy, start)
            }
        }
        var downloading = machine(after: .shortcut, .picked(.document(source)))
        for event in [CaptureEvent.escape, .returnKey, .collectionEnded, .saveFinished] {
            XCTAssertEqual(downloading.handle(event), [], "\(event)")
            XCTAssertEqual(downloading.phase, .downloadingDocument(source))
        }
    }

    // MARK: - Document formats

    func testDocumentFormatsAreRememberedSeparatelyFromPageFormats() throws {
        let suite = "PageCaptureTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(ExportFormatPreference.load(from: defaults, kind: .document), [.original, .markdown], "nothing stored")
        ExportFormatPreference.save([.html], to: defaults)
        ExportFormatPreference.save([.original], to: defaults, kind: .document)
        XCTAssertEqual(ExportFormatPreference.load(from: defaults), [.html])
        XCTAssertEqual(ExportFormatPreference.load(from: defaults, kind: .document), [.original])
        XCTAssertEqual(defaults.stringArray(forKey: "exportFormats"), ["html"], "the page key is unchanged")

        ExportFormatPreference.save([.markdown, .pdf], to: defaults, kind: .document)
        XCTAssertEqual(ExportFormatPreference.load(from: defaults, kind: .document), [.markdown], "only document formats")
        ExportFormatPreference.save([.original, .pdf], to: defaults)
        XCTAssertEqual(ExportFormatPreference.load(from: defaults), [.pdf], "only page formats")
    }

    func testFormatsOfferedPerKind() {
        XCTAssertEqual(ExportSaveKind.page.formats.map(\.title), ["HTML", "PDF", "Markdown"])
        XCTAssertEqual(ExportSaveKind.document.formats.map(\.title), ["Original", "Markdown"])
        XCTAssertEqual(ExportFormat.allCases, ExportSaveKind.page.formats)
    }
}

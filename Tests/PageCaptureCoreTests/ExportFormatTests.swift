import AppKit
import XCTest
@testable import PageCaptureCore

@MainActor
final class ExportFormatTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        suite = "PageCaptureTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testTheOldPopupChoiceIsMigrated() {
        XCTAssertEqual(ExportFormatPreference.load(from: defaults), [.pdf, .markdown], "nothing stored")
        for (old, formats) in [("pdf", [ExportFormat.pdf]), ("markdown", [.markdown]), ("both", [.pdf, .markdown])] {
            defaults.set(old, forKey: "exportFormat")
            XCTAssertEqual(ExportFormatPreference.load(from: defaults), Set(formats), old)
        }
    }

    func testTheTickedSetIsRemembered() {
        defaults.set("pdf", forKey: "exportFormat")
        ExportFormatPreference.save([.markdown, .html], to: defaults)
        XCTAssertEqual(ExportFormatPreference.load(from: defaults), [.html, .markdown])
        XCTAssertNil(defaults.object(forKey: "exportFormat"))
        ExportFormatPreference.save([.html, .pdf, .markdown], to: defaults)
        XCTAssertEqual(ExportFormatPreference.load(from: defaults), Set(ExportFormat.allCases))
    }

    func testChooserHasOneCheckboxPerFormatInOrder() {
        let chooser = FormatChooser(selection: [.html, .markdown])
        XCTAssertEqual(chooser.checkboxes.map(\.title), ["HTML", "PDF", "Markdown"])
        XCTAssertEqual(chooser.checkboxes.map(\.state), [.on, .off, .on])
        XCTAssertTrue(chooser.checkboxes.allSatisfy { $0.isDescendant(of: chooser.view) })
        XCTAssertGreaterThan(chooser.view.frame.width, 0)
        XCTAssertEqual(chooser.selection, [.html, .markdown])
    }

    func testTheLastTickedFormatCannotBeUnticked() {
        let chooser = FormatChooser(selection: [.pdf])
        chooser.checkboxes[1].performClick(nil)
        XCTAssertEqual(chooser.selection, [.pdf])
        chooser.checkboxes[0].performClick(nil)
        chooser.checkboxes[1].performClick(nil)
        XCTAssertEqual(chooser.selection, [.html])
    }
}

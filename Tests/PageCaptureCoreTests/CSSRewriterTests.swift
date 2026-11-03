import XCTest
@testable import PageCaptureCore

final class CSSRewriterTests: XCTestCase {
    private let base = URL(string: "https://site.test/assets/css/main.css")!

    private func rewrite(_ css: String, imported: [String: String] = [:]) -> String {
        CSSRewriter.rewrite(css, base: base, imported: { imported[$0.absoluteString] },
                            resource: { "R[\($0.absoluteString)]" })
    }

    func testURLsResolveAgainstTheStylesheetQuotedOrNot() {
        let css = """
        a { background: url(img/a.png) } b { background: URL( "../b.png" ) }
        c { background: url('/c.png') } d { background: url(https://cdn.test/d.png) }
        e { background: url(//cdn.test/e.png) }
        """
        let out = rewrite(css)
        for expected in ["https://site.test/assets/css/img/a.png", "https://site.test/assets/b.png",
                         "https://site.test/c.png", "https://cdn.test/d.png", "https://cdn.test/e.png"] {
            XCTAssertTrue(out.contains(#"url("R[\#(expected)]")"#), "\(expected) in \(out)")
        }
        XCTAssertEqual(CSSRewriter.references(in: css, base: base).resources.map(\.absoluteString),
                       ["https://site.test/assets/css/img/a.png", "https://site.test/assets/b.png",
                        "https://site.test/c.png", "https://cdn.test/d.png", "https://cdn.test/e.png"])
    }

    func testDataAndFragmentURLsCommentsAndStringsAreUntouched() {
        let css = #"""
        a { background: url(data:image/png;base64,iVBO=) }
        b { mask: url("data:image/svg+xml,%3Csvg%2F%3E") } c { filter: url(#blur) }
        /* url(comment.png) */ d::before { content: "url(text.png)" } e { x: myurl(y.png) }
        """#
        XCTAssertEqual(rewrite(css), css)
        XCTAssertEqual(CSSRewriter.references(in: css, base: base), CSSRewriter.References())
    }

    func testImportsAreInlinedWithTheirConditions() {
        let css = """
        @charset "utf-8";
        @import url(reset.css);
        @import "print.css" print;
        @import url('theme.css') layer(theme) supports(display: grid) screen and (min-width: 600px);
        @import "missing.css";
        p { color: red }
        """
        let refs = CSSRewriter.references(in: css, base: base)
        XCTAssertEqual(refs.imports.map(\.absoluteString), ["reset.css", "print.css", "theme.css", "missing.css"]
            .map { "https://site.test/assets/css/" + $0 })
        let out = rewrite(css, imported: [
            "https://site.test/assets/css/reset.css": "RESET",
            "https://site.test/assets/css/print.css": "PRINT",
            "https://site.test/assets/css/theme.css": "THEME",
        ])
        XCTAssertFalse(out.contains("@import"), out)
        XCTAssertFalse(out.contains("@charset"), out)
        XCTAssertTrue(out.contains("RESET"), out)
        XCTAssertTrue(out.contains("@media print {\nPRINT\n}"), out)
        XCTAssertTrue(out.contains("@layer theme {\n@supports (display: grid) {\n@media screen and (min-width: 600px) {\nTHEME\n}\n}\n}"), out)
        XCTAssertTrue(out.hasSuffix("p { color: red }"), out)
    }

    func testImportInsideABlockIsNotAnImport() {
        XCTAssertEqual(CSSRewriter.references(in: "a { --x: 1 } @media print { b { c: d } }", base: base).imports, [])
    }

    func testResourceValuesAreEscaped() {
        let out = CSSRewriter.rewrite("a { b: url(x.png) }", base: base, imported: { _ in nil },
                                      resource: { _ in #"q"u\o"# })
        XCTAssertEqual(out, #"a { b: url("q\"u\\o") }"#)
    }
}

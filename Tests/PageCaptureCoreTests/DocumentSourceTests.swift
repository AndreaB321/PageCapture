import XCTest
@testable import PageCaptureCore

final class DocumentSourceTests: XCTestCase {
    private func detect(_ string: String, mime: String? = nil) -> DocumentDetection? {
        DocumentSource.detect(url: URL(string: string)!, mimeType: mime)
    }

    private func document(_ url: String, _ kind: DocumentKind) -> DocumentDetection {
        .document(DocumentSource(url: URL(string: url)!, kind: kind))
    }

    func testEachSupportedExtensionIsADocument() {
        for kind in DocumentKind.allCases {
            let url = "https://example.com/files/report.\(kind.rawValue)"
            XCTAssertEqual(detect(url), document(url, kind), kind.rawValue)
        }
    }

    func testExtensionIgnoresCaseQueryAndFragment() {
        let url = "https://example.com/Files/REPORT.PDF?download=1&sig=a.docx#page=2"
        XCTAssertEqual(detect(url), document(url, .pdf), "the query and fragment are kept in the URL")
        XCTAssertEqual(detect("http://example.com/a/Deck.PpTx"), document("http://example.com/a/Deck.PpTx", .pptx))
        XCTAssertNil(detect("https://example.com/view?file=report.pdf"), "an extension in the query does not count")
        XCTAssertNil(detect("https://example.com/page#report.pdf"))
    }

    func testMIMETypeNamesTheKindWhenThePathDoesNot() {
        let url = "https://example.com/download.php?id=7"
        XCTAssertEqual(detect(url, mime: "application/pdf"), document(url, .pdf))
        XCTAssertEqual(detect(url, mime: "Application/PDF; charset=binary"), document(url, .pdf))
        XCTAssertEqual(detect(url, mime: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"),
                       document(url, .xlsx))
        XCTAssertEqual(detect(url, mime: "application/vnd.ms-excel"), document(url, .xls))
        XCTAssertNil(detect(url, mime: "text/html"))
        XCTAssertNil(detect(url))
    }

    func testTheExtensionWinsOverTheMIMEType() {
        let url = "https://example.com/report.docx"
        XCTAssertEqual(detect(url, mime: "text/html"), document(url, .docx), "a sign-in page is caught by the download")
    }

    func testOnlyHTTPURLsAreDocuments() {
        for url in ["javascript:open('a.pdf')", "data:application/pdf;base64,JVBERi0=", "file:///Users/me/a.pdf",
                    "blob:https://example.com/0a1b-2c3d", "ftp://example.com/a.pdf", "about:blank"] {
            XCTAssertNil(detect(url, mime: "application/pdf"), url)
            XCTAssertNil(DocumentSource(url: URL(string: url)!, mimeType: "application/pdf"), url)
        }
    }

    func testLegacyOfficeTypesAreUnsupported() {
        XCTAssertEqual(detect("https://example.com/old.DOC"), .unavailable(.unsupportedType("doc")))
        XCTAssertEqual(detect("https://example.com/old.ppt"), .unavailable(.unsupportedType("ppt")))
        XCTAssertEqual(detect("https://example.com/get?id=1", mime: "application/msword"),
                       .unavailable(.unsupportedType("doc")))
        XCTAssertNil(DocumentSource(url: URL(string: "https://example.com/old.doc")!))
    }

    func testOrdinaryPagesAreNotDocuments() {
        XCTAssertNil(detect("https://example.com/"))
        XCTAssertNil(detect("https://example.com/article.html", mime: "text/html"))
        XCTAssertNil(detect("https://docs.google.com/document/d/abc/edit"), "a Google Docs editor is a page")
    }

    // MARK: - Viewers

    func testOfficeViewersAreUnwrapped() {
        // The original is `https://files.example.com/Q3%20Report.docx?sig=a%26b`, encoded once more.
        let encoded = "https%3A%2F%2Ffiles.example.com%2FQ3%2520Report.docx%3Fsig%3Da%2526b"
        for path in ["op/embed.aspx", "op/view.aspx", "OP/Embed.aspx"] {
            let viewer = "https://view.officeapps.live.com/\(path)?src=\(encoded)&wdStartOn=1"
            XCTAssertEqual(detect(viewer, mime: "text/html"),
                           document("https://files.example.com/Q3%20Report.docx?sig=a%26b", .docx), path)
            XCTAssertEqual(DocumentSource(url: URL(string: viewer)!)?.url.absoluteString,
                           "https://files.example.com/Q3%20Report.docx?sig=a%26b")
        }
    }

    func testGoogleViewersAreUnwrapped() {
        let expected = document("https://example.com/paper.pdf", .pdf)
        for viewer in ["https://docs.google.com/viewer?url=https%3A%2F%2Fexample.com%2Fpaper.pdf&embedded=true",
                       "https://docs.google.com/gview?embedded=true&url=https://example.com/paper.pdf",
                       "https://drive.google.com/viewerng/viewer?url=https%3A%2F%2Fexample.com%2Fpaper.pdf",
                       "https://DOCS.Google.com/viewer?url=https%253A%252F%252Fexample.com%252Fpaper.pdf"] {
            XCTAssertEqual(detect(viewer), expected, viewer)
        }
    }

    func testViewerWithoutAUsableURLIsUnavailable() {
        for viewer in ["https://view.officeapps.live.com/op/embed.aspx",
                       "https://view.officeapps.live.com/op/embed.aspx?src=",
                       "https://view.officeapps.live.com/op/embed.aspx?url=https%3A%2F%2Fexample.com%2Fa.docx",
                       "https://docs.google.com/viewer?url=javascript%3Aalert(1)",
                       "https://docs.google.com/viewer?url=data%3Aapplication%2Fpdf%3Bbase64%2CJVBERi0%3D",
                       "https://docs.google.com/viewer?url=%2Ffiles%2Fa.pdf"] {
            XCTAssertEqual(detect(viewer), .unavailable(.noURLInViewer), viewer)
            XCTAssertNil(DocumentSource(url: URL(string: viewer)!), viewer)
        }
    }

    func testViewerOfAnUnsupportedTypeIsUnavailable() {
        XCTAssertEqual(detect("https://view.officeapps.live.com/op/embed.aspx?src=https%3A%2F%2Fexample.com%2Fold.doc"),
                       .unavailable(.unsupportedType("doc")))
        XCTAssertEqual(detect("https://docs.google.com/viewer?url=https%3A%2F%2Fexample.com%2Fdownload%3Fid%3D3"),
                       .unavailable(.unsupportedType("")), "no recognisable type")
    }

    func testANestedViewerIsUnwrappedOnceAtMost() {
        let office = "https://view.officeapps.live.com/op/embed.aspx?src=https%3A%2F%2Fexample.com%2Fdeck.pptx"
        let google = "https://docs.google.com/viewer?url=" + office.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        XCTAssertEqual(detect(google), document("https://example.com/deck.pptx", .pptx))
        let thrice = "https://drive.google.com/viewerng/viewer?url="
            + google.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        XCTAssertEqual(detect(thrice), .unavailable(.noURLInViewer))
    }

    func testViewerLookalikesAreNotViewers() {
        XCTAssertNil(detect("https://view.officeapps.live.com.evil.test/op/embed.aspx?src=https%3A%2F%2Fa.test%2Fb.docx"))
        XCTAssertNil(detect("https://docs.google.com/viewerx?url=https%3A%2F%2Fa.test%2Fb.pdf"))
    }

    func testReasonsHoldNoPaths() {
        XCTAssertEqual(DocumentDownloadError.tooLarge.reason, "it is larger than 500 MB")
        XCTAssertEqual(DocumentDownloadError.unsupportedType("doc").reason, ".doc files are not supported")
        XCTAssertEqual(DocumentDownloadError.httpStatus(404).reason, "HTTP 404")
    }
}

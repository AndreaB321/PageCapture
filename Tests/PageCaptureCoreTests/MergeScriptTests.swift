import JavaScriptCore
import XCTest
@testable import PageCaptureCore

/// Runs `merge.js` in JavaScriptCore against hand-built snapshots.
/// Helpers: `E(id, tag, [attrs]?, ...children)` and `T(id, text)` build snapshot nodes; build each
/// snapshot fresh, because merge adopts snapshot nodes into the accumulated tree.
final class MergeScriptTests: XCTestCase {
    private struct Result: Decodable {
        var html: String
        var imageURLs: [String]
        var added: [Int]
    }

    private var context: JSContext!

    override func setUp() {
        super.setUp()
        context = JSContext()
        context.exceptionHandler = { _, exception in
            XCTFail("JavaScript exception: \(exception?.toString() ?? "?")")
        }
        context.evaluateScript(CaptureScripts.merge)
        context.evaluateScript("""
        function E(id, tag, ...rest) {
          const attrs = rest.length && Array.isArray(rest[0]) ? rest.shift() : [];
          return { id, tag, attrs, children: rest };
        }
        function T(id, text) { return { id, text }; }
        function run(snapshots) {
          let tree = null;
          const added = [];
          for (const s of snapshots) {
            const merged = PageCaptureMerge.merge(tree, s);
            tree = merged.tree;
            added.push(merged.added);
          }
          const out = PageCaptureMerge.serialize(tree);
          return JSON.stringify({ html: out.html, imageURLs: out.imageURLs, added });
        }
        // A list row: element id `id`, text node id `id + 1000`.
        function row(id, label) { return E(id, 'li', T(id + 1000, label)); }
        """)
    }

    /// `snapshots` is a JS expression evaluating to an array of root snapshots.
    private func run(_ snapshots: String) throws -> Result {
        let json = try XCTUnwrap(context.evaluateScript("run(\(snapshots))")?.toString())
        return try JSONDecoder().decode(Result.self, from: Data(json.utf8))
    }

    func testAppendedContentIsAddedInOrder() throws {
        let result = try run("""
        [ E(1, 'ul', row(2, 'A'), row(3, 'B')),
          E(1, 'ul', row(2, 'A'), row(3, 'B'), row(4, 'C')) ]
        """)
        XCTAssertEqual(result.html, "<li>A</li><li>B</li><li>C</li>")
        XCTAssertEqual(result.added, [2, 1])
    }

    func testContentThePageRemovedIsKeptInPlace() throws {
        // A virtualised list: rows scrolled out of view leave the DOM.
        let result = try run("""
        [ E(1, 'ul', row(10, 'A'), row(11, 'B'), row(12, 'C')),
          E(1, 'ul', row(12, 'C'), row(13, 'D'), row(14, 'E')),
          E(1, 'ul', row(14, 'E'), row(15, 'F')) ]
        """)
        XCTAssertEqual(result.html, "<li>A</li><li>B</li><li>C</li><li>D</li><li>E</li><li>F</li>")
        XCTAssertEqual(result.added, [3, 2, 1])
    }

    func testReRenderedNodesWithTheSameContentAreNotDuplicated() throws {
        // Every render replaces the rows with new nodes (new ids) carrying the same content.
        let result = try run("""
        [ E(1, 'ul', row(10, 'A'), row(11, 'B')),
          E(1, 'ul', row(20, 'A'), row(21, 'B'), row(22, 'C')),
          E(1, 'ul', row(31, 'B'), row(32, 'C'), row(33, 'D')) ]
        """)
        XCTAssertEqual(result.html, "<li>A</li><li>B</li><li>C</li><li>D</li>")
        XCTAssertEqual(result.added, [2, 1, 1])
    }

    func testAChangedNodeIsUpdatedNotDuplicated() throws {
        // A lazy image swaps its placeholder for the real source.
        let result = try run("""
        [ E(1, 'div', E(2, 'img', [['src', 'https://a.test/blank.gif']]), T(3, 'loading')),
          E(1, 'div', E(2, 'img', [['src', 'https://a.test/photo.jpg'], ['alt', 'x']]), T(3, 'loaded')) ]
        """)
        XCTAssertEqual(result.html, #"<img src="https://a.test/photo.jpg" alt="x">loaded"#)
        XCTAssertEqual(result.imageURLs, ["https://a.test/photo.jpg"])
        XCTAssertEqual(result.added, [1, 0]) // `added` counts elements
    }

    func testIdenticalSiblingsThatAreBothLiveAreKept() throws {
        let result = try run("""
        [ E(1, 'div', E(2, 'p', T(3, 'same')), E(4, 'hr'), E(5, 'p', T(6, 'same')), E(7, 'hr')),
          E(1, 'div', E(2, 'p', T(3, 'same')), E(4, 'hr'), E(5, 'p', T(6, 'same')), E(7, 'hr')) ]
        """)
        XCTAssertEqual(result.html, "<p>same</p><hr><p>same</p><hr>")
        XCTAssertEqual(result.added, [4, 0])
    }

    func testNewStructuralNodesAreNotAbsorbedIntoEarlierIdenticalOnes() throws {
        // After a scroll the page replaced every node: the new separators equal the old ones but follow
        // new rows, so they are new content in order, not the earlier separators re-rendered.
        let result = try run("""
        [ E(1, 'div', row(2, 'r1'), E(3, 'hr'), row(4, 'r2'), E(5, 'hr')),
          E(1, 'div', row(6, 'r3'), E(7, 'hr'), row(8, 'r4'), E(9, 'hr')) ]
        """)
        XCTAssertEqual(result.html, "<li>r1</li><hr><li>r2</li><hr><li>r3</li><hr><li>r4</li><hr>")
        XCTAssertEqual(result.added, [4, 4])
    }

    func testTextOfALiveElementShowsItsCurrentValue() throws {
        // A clock replaces its text node every tick; the old text is not removed content to keep,
        // and a new text node is not new content for the stall decision.
        let result = try run("""
        [ E(1, 'div', E(2, 'span', T(3, '12:00:00'))),
          E(1, 'div', E(2, 'span', T(4, '12:00:01'))),
          E(1, 'div', E(2, 'span', T(5, '12:00:02'))) ]
        """)
        XCTAssertEqual(result.html, "<span>12:00:02</span>")
        XCTAssertEqual(result.added, [1, 0, 0])
    }

    func testNewContentBeforeTheFirstKnownNodeGoesBeforeIt() throws {
        let result = try run("""
        [ E(1, 'ul', row(10, 'A'), row(12, 'C')),
          E(1, 'ul', row(11, 'B'), row(12, 'C')) ]
        """)
        // A left the page; B is new and precedes C.
        XCTAssertEqual(result.html, "<li>A</li><li>B</li><li>C</li>")
    }

    func testNewContentFollowsRemovedRecordsUpToTheNextLiveOne() throws {
        let result = try run("""
        [ E(1, 'ul', row(10, 'A'), row(11, 'X'), row(12, 'Y'), row(13, 'B')),
          E(1, 'ul', row(10, 'A'), row(14, 'NEW'), row(13, 'B')) ]
        """)
        XCTAssertEqual(result.html, "<li>A</li><li>X</li><li>Y</li><li>NEW</li><li>B</li>")
    }

    func testListsInsideWrappersAreMergedRecursively() throws {
        // The scroll container holds one wrapper whose padding and rows change as it virtualises.
        let result = try run("""
        [ E(1, 'div', E(2, 'div', [['style', 'padding-top:0px']], row(10, 'A'), row(11, 'B'))),
          E(1, 'div', E(2, 'div', [['style', 'padding-top:40px']], row(11, 'B'), row(12, 'C'))),
          E(1, 'div', E(2, 'div', [['style', 'padding-top:80px']], row(22, 'C'), row(23, 'D'))) ]
        """)
        XCTAssertEqual(
            result.html,
            #"<div style="padding-top:80px"><li>A</li><li>B</li><li>C</li><li>D</li></div>"#
        )
    }

    func testSerialisationEscapesTextAndAttributes() throws {
        let result = try run("""
        [ E(1, 'div',
            E(2, 'p', [['title', 'say "hi" & bye']], T(3, '1 < 2 & 3 > 2')),
            E(4, 'style', T(5, 'a > b { color: red }')),
            E(6, 'br'),
            E(7, 'img', [['src', 'https://a.test/1.png']]),
            E(8, 'img', [['src', 'https://a.test/2.png']]),
            E(9, 'img', [['src', 'https://a.test/1.png']]),
            E(10, 'img')) ]
        """)
        XCTAssertEqual(result.html, """
        <p title="say &quot;hi&quot; &amp; bye">1 &lt; 2 &amp; 3 &gt; 2</p>\
        <style>a > b { color: red }</style><br>\
        <img src="https://a.test/1.png"><img src="https://a.test/2.png"><img src="https://a.test/1.png"><img>
        """)
        XCTAssertEqual(result.imageURLs, ["https://a.test/1.png", "https://a.test/2.png"])
    }
}

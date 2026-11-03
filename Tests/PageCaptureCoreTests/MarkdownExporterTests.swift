import AppKit
import XCTest
@testable import PageCaptureCore

/// Runs `markdown.js` in an off-screen WKWebView against `Fixtures/markdown.html`, which has one of
/// each supported element, and compares with `Fixtures/markdown.md`.
@MainActor
final class MarkdownExporterTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testConvertsEachElementTypeOfTheFixture() async throws {
        let markdown = try await MarkdownExporter.markdown(fromHTML: try fixture("markdown.html"), images: [
            "https://cdn.example.com/a.png": "images/001-a.png",
            "https://cdn.example.com/c.png": "images/003-c.png",
        ])
        let expected = try fixture("markdown.md")
        XCTAssertEqual(markdown, expected)
        if markdown != expected {
            let got = markdown.components(separatedBy: "\n"), want = expected.components(separatedBy: "\n")
            for i in 0..<max(got.count, want.count) where (i < got.count ? got[i] : nil) != (i < want.count ? want[i] : nil) {
                print("line \(i + 1):\n  got:  \(i < got.count ? got[i] : "<none>")\n  want: \(i < want.count ? want[i] : "<none>")")
            }
        }
    }

    func testDropsEmptyIconLinksAndKeepsLinkedImages() async throws {
        let markdown = try await MarkdownExporter.markdown(
            fromHTML: #"<p><a href="https://x.test/"><svg></svg></a><a href="https://x.test/p"><img src="https://x.test/i.png" alt=""></a></p>"#,
            images: [:])
        XCTAssertEqual(markdown, "[![](https://x.test/i.png)](https://x.test/p)\n")
    }

    func testNestedUnorderedListsAndLooseItems() async throws {
        let markdown = try await MarkdownExporter.markdown(
            fromHTML: "<ul><li><p>First para</p><p>more</p></li><li>Next<ul><li>Deep<ul><li>Deeper</li></ul></li></ul></li></ul>",
            images: [:])
        XCTAssertEqual(markdown, "- First para\n\n  more\n\n- Next\n  - Deep\n    - Deeper\n")
    }

    // MARK: Videos

    /// The figure capture.js leaves for video `index`.
    private func figure(_ index: Int, poster: String? = nil, title: String = "Clip") -> String {
        let img = poster.map { #"<img src="\#($0)" alt="\#(title)">"# } ?? ""
        return #"<figure data-pc-video="\#(index)">\#(img)<figcaption>Video: \#(title)</figcaption></figure>"#
    }

    func testSavedVideoBecomesItsPreviewImageLinkingToTheLocalFile() async throws {
        let html = "<p>Intro</p>" + figure(0, poster: "https://cdn.x.test/p.jpg") + figure(1)
        let markdown = try await MarkdownExporter.markdown(fromHTML: html, images: [
            "https://cdn.x.test/p.jpg": "images/002-p.jpg",
        ], videos: [
            // The preview the downloader chose wins over the figure's image.
            0: VideoLink(href: "videos/001-clip.mp4", posterFile: "images/005-poster.jpg", title: "Clip", outcome: .saved),
            // No poster in the page: a frame made after capture.
            1: VideoLink(href: "videos/002-other.mp4", posterFile: "images/006-frame.jpg", title: "Other", outcome: .saved),
        ])
        XCTAssertEqual(markdown, """
            Intro

            [![Video: Clip](images/005-poster.jpg)](videos/001-clip.mp4)

            [![Video: Other](images/006-frame.jpg)](videos/002-other.mp4)

            """)
    }

    func testSavedVideoWithoutPreviewLinksItsCaption() async throws {
        let markdown = try await MarkdownExporter.markdown(fromHTML: figure(0), images: [:], videos: [
            0: VideoLink(href: "videos/001-clip.mp4", posterFile: nil, title: "Clip", outcome: .saved),
        ])
        XCTAssertEqual(markdown, "[Video: Clip](videos/001-clip.mp4)\n")
    }

    func testProtectedVideoLinksTheOriginalWithANote() async throws {
        let markdown = try await MarkdownExporter.markdown(fromHTML: figure(0), images: [:], videos: [
            0: VideoLink(href: "https://www.youtube.com/watch?v=abc", posterFile: "images/003-t.jpg",
                         title: "Clip", outcome: .protected),
        ])
        XCTAssertEqual(markdown,
            "[![Video: Clip](images/003-t.jpg)](https://www.youtube.com/watch?v=abc) *(protected video, linked to the original)*\n")
    }

    func testFailedVideoLinksTheOriginalWithTheReason() async throws {
        let markdown = try await MarkdownExporter.markdown(fromHTML: figure(0), images: [:], videos: [
            0: VideoLink(href: "https://x.test/live/master.m3u8", posterFile: nil, title: "Clip",
                         outcome: .failed("HTTP 403 for the_stream")),
        ])
        XCTAssertEqual(markdown,
            #"[Video: Clip](https://x.test/live/master.m3u8) *(video could not be saved: HTTP 403 for the\_stream)*"# + "\n")
    }

    func testSavedVideoAndPosterLinksResolveToTheFilesWhateverTheTitle() async throws {
        let stem = ExportNaming.videoFileStem(index: 0, title: "Lesson #2: Setup? 100% (part 1)", url: "https://x.test/v.mp4")
        let videoPath = ExportNaming.relativeVideoPath(stem + ".mp4")
        // A hostile name too: the encoding must hold even for names the sanitiser would not produce.
        let posterPath = ExportNaming.relativeImagePath("002-we ird#?%&=+.jpg")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MDLinks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        for path in [videoPath, posterPath] {
            let file = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: file)
        }
        let markdown = try await MarkdownExporter.markdown(fromHTML: figure(0, title: "Lesson"), images: [:], videos: [
            0: VideoLink(href: videoPath, posterFile: posterPath, title: "Lesson", outcome: .saved),
        ])
        let match = try XCTUnwrap(markdown.firstMatch(of: /\[!\[Video: Lesson\]\((\S+)\)\]\((\S+)\)/))
        for (destination, path) in [(String(match.output.1), posterPath), (String(match.output.2), videoPath)] {
            XCTAssertFalse(destination.contains("#") || destination.contains("?"), destination)
            let resolved = try XCTUnwrap(URL(string: destination, relativeTo: folder.appendingPathComponent("page.md")))
            XCTAssertNil(resolved.fragment)
            XCTAssertNil(resolved.query)
            XCTAssertTrue(FileManager.default.fileExists(atPath: resolved.path), "\(destination) -> \(resolved.path) for \(path)")
            XCTAssertEqual(resolved.standardizedFileURL.path, folder.appendingPathComponent(path).standardizedFileURL.path)
        }
    }

    func testVideoTitleAndPathsWithSpaces() async throws {
        let markdown = try await MarkdownExporter.markdown(fromHTML: figure(0, title: "My [best] clip") + figure(1),
                                                           images: [:], videos: [
            0: VideoLink(href: "videos/001-My best clip (1).mp4", posterFile: "images/004-a b.jpg",
                         title: "My [best] clip", outcome: .saved),
            1: VideoLink(href: "videos/002-My clip.mp4", posterFile: nil, title: "My *clip*", outcome: .saved),
        ])
        XCTAssertEqual(markdown, #"""
            [![Video: My \[best\] clip](images/004-a%20b.jpg)](videos/001-My%20best%20clip%20%281%29.mp4)

            [Video: My \*clip\*](videos/002-My%20clip.mp4)

            """#)
    }

    func testVideoFigureWithoutAnEntryKeepsItsPosterAndCaption() async throws {
        let markdown = try await MarkdownExporter.markdown(
            fromHTML: figure(3, poster: "https://cdn.x.test/p.jpg"),
            images: ["https://cdn.x.test/p.jpg": "images/002-p.jpg"],
            videos: [0: VideoLink(href: "videos/001-clip.mp4", posterFile: nil, title: "Clip", outcome: .saved)])
        XCTAssertEqual(markdown, "![Clip](images/002-p.jpg)\n\nVideo: Clip\n")
    }

    // MARK: Page structure

    private func md(_ html: String, images: [String: String] = [:], videos: [Int: VideoLink] = [:]) async throws -> String {
        try await MarkdownExporter.markdown(fromHTML: html, images: images, videos: videos)
    }

    /// A memo laid out as a one-column table: each row's paragraphs, lists and broken lines stay blocks.
    func testLayoutTableIsUnwrappedIntoItsBlocks() async throws {
        let markdown = try await md("""
            <table class="memo"><tbody>
            <tr><td><p><strong>1.0 Introduction</strong></p></td></tr>
            <tr><td><p>This memo sets out the team's tools.</p></td></tr>
            <tr><td><p><strong>2.1 Primary Tool Category: Language Models</strong></p></td></tr>
            <tr><td><p>This will be the team's core capability.</p>
              <p><strong>Expressive and Creative Language Generation:</strong> For drafting copy.</p>
              <ul><li>Blog posts</li><li>Emails</li></ul>
              <p><strong>Selected Tool Example: ChatGPT, Claude 3.</strong></p>
              <div><strong>Technical and Logical Reasoning:</strong> For code.<br><strong>Selected Tool Example: Copilot.</strong></div>
            </td></tr>
            </tbody></table>
            """)
        XCTAssertEqual(markdown, """
            **1.0 Introduction**

            This memo sets out the team's tools.

            **2.1 Primary Tool Category: Language Models**

            This will be the team's core capability.

            **Expressive and Creative Language Generation:** For drafting copy.

            - Blog posts
            - Emails

            **Selected Tool Example: ChatGPT, Claude 3.**

            **Technical and Logical Reasoning:** For code.\u{20}\u{20}
            **Selected Tool Example: Copilot.**

            """)
    }

    /// Title rows spanning both columns, then an icon cell and a text cell.
    func testPitfallsTableBecomesTitleImageAndTextInOrder() async throws {
        let markdown = try await md("""
            <table><tbody>
            <tr><td colspan="2"><p><strong>Pitfall 1: Over-trusting output</strong></p></td></tr>
            <tr><td><figure><a href="https://x.test/p1"><img src="https://x.test/warn.png" alt="Warning"></a></figure></td>
                <td><p>Always verify facts.</p></td></tr>
            <tr><td colspan="2"><p><strong>Pitfall 2: Leaking data</strong></p></td></tr>
            <tr><td><figure><img src="https://x.test/lock.png" alt=""></figure></td><td><p>Never paste secrets.</p></td></tr>
            </tbody></table>
            """, images: ["https://x.test/warn.png": "images/002-warn.png"])
        XCTAssertEqual(markdown, """
            **Pitfall 1: Over-trusting output**

            [![Warning](images/002-warn.png)](https://x.test/p1)

            Always verify facts.

            **Pitfall 2: Leaking data**

            ![](https://x.test/lock.png)

            Never paste secrets.

            """)
        XCTAssertFalse(markdown.contains("<table"), markdown)
        XCTAssertFalse(markdown.contains("|"), markdown)
    }

    func testDataTableWithMergedCellsKeepsItsColumnsAligned() async throws {
        let markdown = try await md("""
            <table><thead><tr><th>Tool</th><th colspan="2">Use</th></tr></thead>
            <tbody><tr><td>ChatGPT</td><td>Drafting</td><td>Chat<br>web</td></tr>
            <tr><td rowspan="2">Copilot</td><td>Code</td><td>IDE</td></tr>
            <tr><td>Review</td><td>PR</td></tr></tbody></table>
            """)
        XCTAssertEqual(markdown, """
            | Tool | Use |  |
            | --- | --- | --- |
            | ChatGPT | Drafting | Chat web |
            | Copilot | Code | IDE |
            |  | Review | PR |

            """)
    }

    // MARK: Checklist tables and visual headings

    /// A ✓ checklist laid out as a table under a sub-heading the page styles (marked by capture.js):
    /// the heading stays a heading and each row becomes one item keeping its ✓.
    func testCheckmarkTableBecomesAListUnderItsVisualHeading() async throws {
        let row = { (title: String, text: String) in
            #"<tr><td class="tick">✓</td><td><strong>\#(title)</strong> \#(text)</td></tr>"#
        }
        let markdown = try await md("""
            <p style="font-weight:700;font-size:20px" data-pc-heading="3">Step 1: The 5-Minute Enterprise Vetting</p>
            <p>Before conducting a formal evaluation of any new AI tool, perform this quick check on their website:</p>
            <table><tbody>
            \(row(#"Find the "Enterprise," "Business," or "Trust" page."#, "The absence of a dedicated enterprise security page is a deal-breaker."))
            \(row("Look for SOC 2 Compliance.", "This should be clearly and proudly stated."))
            \(row("Check the data policy.", "Your data must not train their models."))
            \(row("Ask for SSO.", #"Single sign-on keeps<br>access under your control."#))
            </tbody></table>
            <p>Step 2: The Formal Evaluation Scorecard</p>
            """)
        XCTAssertEqual(markdown, """
            ### Step 1: The 5-Minute Enterprise Vetting

            Before conducting a formal evaluation of any new AI tool, perform this quick check on their website:

            - ✓ **Find the "Enterprise," "Business," or "Trust" page.** The absence of a dedicated enterprise security page is a deal-breaker.
            - ✓ **Look for SOC 2 Compliance.** This should be clearly and proudly stated.
            - ✓ **Check the data policy.** Your data must not train their models.
            - ✓ **Ask for SSO.** Single sign-on keeps\u{20}\u{20}
              access under your control.

            Step 2: The Formal Evaluation Scorecard

            """)
        XCTAssertFalse(markdown.contains("\n✓\n"), markdown)
    }

    /// Numbered rows become an ordered list; a header row across the table becomes its title.
    func testNumberedTableBecomesAnOrderedList() async throws {
        let markdown = try await md("""
            <table><thead><tr><th colspan="2">Setup</th></tr></thead><tbody>
            <tr><td>1.</td><td>Install the app.</td></tr>
            <tr><td>2.</td><td>Sign in with <em>your</em> account.</td></tr>
            <tr><td>3.</td><td>Pick a page.</td></tr>
            </tbody></table>
            """)
        XCTAssertEqual(markdown, """
            **Setup**

            1. Install the app.
            2. Sign in with *your* account.
            3. Pick a page.

            """)
    }

    /// Rows marked by a small icon become plain bullets without the icon; a caption marked as a
    /// heading becomes one.
    func testIconMarkedTableBecomesPlainBullets() async throws {
        let markdown = try await md("""
            <table><caption data-pc-heading="4">Benefits</caption><tbody>
            <tr><td><img src="https://x.test/check.png" width="16" height="16" alt=""></td><td>Faster reviews.</td></tr>
            <tr><td><img src="https://x.test/check.png" width="16" height="16" alt=""></td><td>Fewer errors.</td></tr>
            </tbody></table>
            """)
        XCTAssertEqual(markdown, "#### Benefits\n\n- Faster reviews.\n- Fewer errors.\n")
    }

    /// Two columns of long text under a header row stay a table.
    func testTwoColumnDataTableStaysATable() async throws {
        let markdown = try await md("""
            <table><thead><tr><th>Criterion</th><th>What to look for</th></tr></thead><tbody>
            <tr><td>Data retention policy</td><td>How long prompts and outputs are stored.</td></tr>
            <tr><td>Model training opt-out</td><td>Whether your data trains their models.</td></tr>
            </tbody></table>
            """)
        XCTAssertEqual(markdown, """
            | Criterion | What to look for |
            | --- | --- |
            | Data retention policy | How long prompts and outputs are stored. |
            | Model training opt-out | Whether your data trains their models. |

            """)
    }

    /// A video.js player around the figure: only the video's link remains.
    func testVideoPlayerChromeIsDropped() async throws {
        let player = """
            <p>Watch this first.</p>
            <div class="video-js vjs-paused vjs-fluid" id="vjs_video_3">
            <figure data-pc-video="0"><img src="https://cdn.x.test/poster.png" alt="Intro"><figcaption>Video: Intro</figcaption></figure>
            <div class="vjs-poster"><picture class="vjs-poster"><img src="https://cdn.x.test/poster.png" alt=""></picture></div>
            <div class="vjs-loading-spinner"><span class="vjs-control-text">Video Player is loading.</span></div>
            <div class="vjs-control-bar"><button class="vjs-play-control" type="button"><span class="vjs-control-text">Play</span></button>
              <div class="vjs-current-time vjs-time-control"><span class="vjs-control-text">Current Time&nbsp;</span><span>0:00</span></div>
              <div class="vjs-duration"><span class="vjs-control-text">Duration&nbsp;</span><span>2:00</span></div>
              <div class="vjs-live-control"><div class="vjs-live-display"><span class="vjs-control-text">Stream Type&nbsp;</span>LIVE</div></div>
              <div class="vjs-playback-rate vjs-menu-button"><div class="vjs-playback-rate-value">1x</div>
                <div class="vjs-menu"><ul class="vjs-menu-content" role="menu"><li class="vjs-menu-item" role="menuitemradio">2x</li>
                <li class="vjs-menu-item" role="menuitemradio">1.75x</li></ul></div></div>
              <div class="vjs-subs-caps-button"><span class="vjs-control-text">Captions</span></div>
            </div>
            <div class="vjs-text-track-settings vjs-modal-dialog" role="dialog"><p class="vjs-control-text">This is a modal window.</p>
              <div class="vjs-modal-dialog-content"><p>Beginning of dialog window. Escape will cancel and close the window.</p>
              <fieldset><legend>Text</legend><label for="c1">Color</label><select id="c1"><option>White</option></select>
              <span>Opacity</span></fieldset><p>End of dialog window.</p></div></div>
            </div>
            <p>Then read on.</p>
            """
        let videos = [0: VideoLink(href: "videos/001-intro.mp4", posterFile: "images/005-poster.png", title: "Intro", outcome: .saved)]
        let markdown = try await md(player, images: ["https://cdn.x.test/poster.png": "images/001-poster.png"], videos: videos)
        XCTAssertEqual(markdown, """
            Watch this first.

            [![Video: Intro](images/005-poster.png)](videos/001-intro.mp4)

            Then read on.

            """)
        // A plain wrapper holding only player controls goes too.
        let wrapped = try await md("""
            <div class="media"><figure data-pc-video="0"><figcaption>Video: Intro</figcaption></figure>
            <div class="controls"><span class="current-time">Current Time 0:00</span><span class="duration">Duration 2:00</span></div></div>
            """, videos: videos)
        XCTAssertEqual(wrapped, "[![Video: Intro](images/005-poster.png)](videos/001-intro.mp4)\n")
    }

    func testSiteChromeIsDroppedAndMainContentKept() async throws {
        let markdown = try await md("""
            <header class="site"><a href="https://x.test/">Example U.</a><nav><ul><li><a href="https://x.test/learn">Learn</a></li></ul></nav></header>
            <a href="#main">Skip to main content</a>
            <nav class="crumbs"><a href="https://x.test/path">Return to Learning Path Overview</a></nav>
            <main id="main"><article><header><h1>Choosing AI tools</h1></header>
            <p>Teams choose generative tools by the work they do most: drafting, summarising, analysing data and
            writing code each favour a different model, and the trade-offs are worth knowing before you commit.</p>
            <nav class="toc"><a href="#s1">Section one</a></nav></article></main>
            <div role="dialog"><p>Cookie preferences</p></div>
            <footer><p>Keep going!</p><a href="#top">Skip to table of contents</a>
            <ul><li><a href="https://x.test/learn">Learn</a></li><li><a href="https://social.test/"><svg></svg></a></li></ul>
            <p>© 2024 Example Systems, Inc.</p></footer>
            """)
        XCTAssertEqual(markdown, """
            # Choosing AI tools

            Teams choose generative tools by the work they do most: drafting, summarising, analysing data and \
            writing code each favour a different model, and the trade-offs are worth knowing before you commit.

            [Section one](#s1)

            """)
    }

    /// A page whose whole content sits in landmark chrome keeps it rather than coming out empty.
    func testContentInsideAHeaderIsKept() async throws {
        let markdown = try await md("""
            <header><h1>Lesson</h1><p>All of this lesson's content lives in the header element.</p>
            <nav><a href="https://x.test/next">Next lesson</a></nav></header>
            """)
        XCTAssertTrue(markdown.hasPrefix("# Lesson\n\nAll of this lesson's content lives in the header element.\n"), markdown)
    }

    func testAccordionHeadersBecomeHeadingsBelowTheSection() async throws {
        let markdown = try await md("""
            <h2>Tools</h2>
            <div class="accordion">
              <div class="item"><button aria-expanded="true" aria-controls="p1">Expressive Generation</button>
                <div id="p1" data-pc-expanded="shown"><p>Alpha text.</p><ul><li>One</li></ul></div></div>
              <div class="item"><button aria-expanded="false" aria-controls="p2">Summarisation</button>
                <div id="p2" data-pc-expanded="hidden" aria-hidden="true"><p>Bravo text.</p></div></div>
            </div>
            <button type="button">Show more</button>
            """)
        XCTAssertEqual(markdown, """
            ## Tools

            ### Expressive Generation

            Alpha text.

            - One

            ### Summarisation

            Bravo text.

            """)
    }

    /// A tab widget as capture.js marks it: the bar is dropped and each panel comes under its title.
    func testTabPanelsBecomeSectionsUnderTheirTitles() async throws {
        let markdown = try await md("""
            <h2>Choosing a model</h2>
            <ul class="nav nav-tabs" role="tablist" data-pc-tabs="">
              <li><a class="nav-link active" href="https://x.test/page#p1" role="tab" aria-controls="p1" aria-selected="true">The Source - Model Hubs</a></li>
              <li><a class="nav-link" href="https://x.test/page#p2" role="tab" aria-controls="p2" aria-selected="false">The Service - Cloud AI Platforms</a></li>
            </ul>
            <div class="tab-content">
              <div class="tab-pane active" id="p1" role="tabpanel" data-pc-tab-title="The Source - Model Hubs" data-pc-expanded="shown"><ul><li>Hub one</li><li>Hub two</li></ul></div>
              <div class="tab-pane" id="p2" role="tabpanel" aria-hidden="true" data-pc-tab-title="The Service - Cloud AI Platforms" data-pc-expanded="hidden"><p>Most businesses will not use models directly from a hub.</p><ul><li>Platform one</li></ul></div>
            </div>
            """)
        XCTAssertEqual(markdown, """
            ## Choosing a model

            ### The Source - Model Hubs

            - Hub one
            - Hub two

            ### The Service - Cloud AI Platforms

            Most businesses will not use models directly from a hub.

            - Platform one

            """)
    }

    /// Tab widgets in HTML without capture marks are paired from their markup: Bootstrap tabs, a
    /// panel without a tab, hidden panels, and panels labelled by their tabs out of tab order.
    func testTabPanelsArePairedFromPlainMarkup() async throws {
        let markdown = try await md("""
            <h1>Course</h1>
            <h2>Choosing a model</h2>
            <ul class="nav nav-tabs">
              <li class="active"><a data-toggle="tab" href="#p1">The Source - Model Hubs</a></li>
              <li><a data-toggle="tab" href="#p2">The Service - Cloud AI Platforms</a></li>
            </ul>
            <div class="tab-content">
              <div class="tab-pane active" id="p1"><ul><li>Hub one</li></ul></div>
              <div class="tab-pane" id="p2"><ul><li>Platform one</li></ul></div>
              <div class="tab-pane" id="p3" role="tabpanel"><p>Orphan panel text.</p></div>
            </div>
            <h2>Plain links</h2>
            <ul class="tabs"><li><a href="#q1">Link Tab One</a></li><li><a href="#q2">Link Tab Two</a></li></ul>
            <div id="q1"><p>Link panel one.</p></div><div id="q2" hidden><p>Link panel two.</p></div>
            <h2>Labelled</h2>
            <div role="tablist"><button role="tab" id="l1">Labelled One</button><button role="tab" id="l2">Labelled Two</button></div>
            <div role="tabpanel" aria-labelledby="l2" hidden><p>Labelled panel two.</p></div>
            <div role="tabpanel" aria-labelledby="l1"><p>Labelled panel one.</p></div>
            """)
        XCTAssertEqual(markdown, """
            # Course

            ## Choosing a model

            ### The Source - Model Hubs

            - Hub one

            ### The Service - Cloud AI Platforms

            - Platform one

            Orphan panel text.

            ## Plain links

            ### Link Tab One

            Link panel one.

            ### Link Tab Two

            Link panel two.

            ## Labelled

            ### Labelled One

            Labelled panel one.

            ### Labelled Two

            Labelled panel two.

            """)
    }

    func testEmptyBulletsAndEmptyListsAreDropped() async throws {
        let markdown = try await md("""
            <ul><li><a href="https://x.test/a"><svg></svg></a></li><li>Real item</li><li> </li></ul>
            <ul><li><a href="https://x.test/b"><i class="icon"></i></a></li></ul>
            <p>After.</p>
            """)
        XCTAssertEqual(markdown, "- Real item\n\nAfter.\n")
    }

    /// Paragraphs inside inline wrappers (custom elements, spans) stay separate paragraphs.
    func testParagraphsInsideInlineWrappersStaySeparate() async throws {
        let markdown = try await md("""
            <c-lesson><span><p><strong>Label one:</strong> text one.</p><p><strong>Label two:</strong> text two.</p></span></c-lesson>
            """)
        XCTAssertEqual(markdown, "**Label one:** text one.\n\n**Label two:** text two.\n")
    }
}

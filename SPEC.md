# PageCapture — specification

A macOS app that captures the full content of a scrolling webpage, or of one frame/scrollable
area inside it, and saves it as PDF and/or Markdown with the images saved separately.

## Capture source

- The app has its own browser window (WKWebView) with an address bar. The user pastes a URL or
  signs in there. Cookies persist between launches (default persistent website data store).
- Content is read from the DOM, not from screenshots, so text, links and original images survive.
  Script runs in every frame, including cross-origin iframes.

## What can be captured

One target per capture:
- an `<iframe>`/`<frame>` (its whole document),
- any scrollable element (e.g. a `<div>` with `overflow: auto|scroll` whose content overflows),
- the page's main content, when the page marks it (`<main>`, `<article>`, `role="main"` or
  `role="article"`), even though it scrolls with the page: the app scrolls the page and collects
  only that element, leaving out the page furniture it also holds (navigation, tool bars, search,
  forms of controls only, and a column of such controls laid out beside the text, such as
  Wikipedia's "Appearance" settings); its title, figures, tables and expanded panels always stay,
  and nothing is left out when the furniture would hold most of its text. Its highlight outlines
  what is captured,
- the whole page,
- an embedded document (see "Documents"): a PDF, Word, Excel or PowerPoint file shown in an
  `<iframe>`/`<frame>`/`<embed>`/`<object>`, or the page itself being a PDF. The app saves the
  original file and/or its Markdown instead of capturing the frame as a page.

## Shortcut and banner

A single shortcut, **⌘⇧S**, works while the app is frontmost:

1. Idle → press ⌘⇧S → **picker mode**. Banner: "Pick a frame, scrolling area or article… (Return = whole page, Esc = cancel)".
   The element under the mouse (frame, scrollable area, main article or embedded document) is highlighted.
   Clicking a highlighted target picks it; clicking outside any target, or pressing Return,
   picks the whole page. Esc, or ⌘⇧S again, cancels back to idle.
2. Target picked → **capturing**. Banner: "Capturing…". The app auto-scrolls the target from the top
   to the bottom, collecting content in order as it loads (lazy images, infinite lists). Content
   already collected is kept even if the page later removes it (virtualised lists); duplicates are
   dropped. Collapsed content in the target (accordions, `<details>`) is expanded first and after
   each scroll step, so every panel appears after its header in both PDF and Markdown. Each tab of
   a tab widget is shown in turn, then the tab selected before is selected again; both exports show
   every tab panel under its tab's title, without the tab bar. A panel whose content loads after it is
   shown (it is empty, shows a loading indicator or its content is still growing) is waited for, up
   to a time limit per panel and in all per capture, before it is collected. Links that navigate,
   menus/popups and form submits are never clicked.
   A picked document is not scrolled: the banner says "Downloading document…" while the app
   downloads the original (see "Documents"); ⌘⇧S cancels the download.
3. Capture ends when the bottom is reached and no more content loads, or when the user presses
   ⌘⇧S again (keeps what was collected). The banner disappears and the save dialog opens.

No banner while idle. The banner is an on-screen overlay clearly visible over the browser content.

## Saving

- A Finder save panel lets the user name the capture and tick any of three formats: **HTML**,
  **PDF**, **Markdown** (at least one). The ticked set is remembered for the next save. For a
  document the panel offers **Original** and **Markdown** instead (see "Documents"), remembered
  separately from the page formats.
- Output: a folder `Name/` containing `Name.html`, `Name.pdf` and/or `Name.md` (the same `Name`
  for each), plus `images/` holding the original image files (from `<img>`/`<picture>`; CSS
  backgrounds are out of scope).
- HTML is one self-contained file that looks like the page on screen: the captured content with
  the site's stylesheets inlined (their fonts and images embedded), images embedded, no scripts,
  readable at any window width, every tab and accordion panel shown under its title. Videos show
  their preview and link to `videos/<file>` (or to the original when not saved). Like the
  Markdown, it leaves out the site's header, navigation and footer, unless they hold most of the
  text. It has none of the PDF's print-only changes.
- Markdown is written by the bundled MarkItDown (below) from the page's cleaned-up HTML: the app
  decides the content and its structure (the rules here), MarkItDown writes it, in the same
  isolated process as documents. Line breaks are kept (as `\` at the end of the line), code blocks
  keep their language, inline code stays on one line, and text that Markdown would read as markup
  (every `~`, and a line starting with `1.`, `#`, `-` or a fence, `<tag>`, and a `|` anywhere in a table
  cell, also in its code, link URLs and image alt text) is escaped, so it stays text and the table
  keeps its columns. If the Markdown cannot be written (MarkItDown fails, or the page is nested too
  deeply for it), the other formats are still saved and the result message says why.
- Markdown references images by relative path `images/<file>`; links (web, `mailto:` and `tel:`)
  are kept as Markdown links with their absolute URLs as the page has them (only control characters,
  spaces, `<`, `>`, backslashes and parentheses are percent-encoded); `javascript:` links keep only their text.
- Markdown writes text the page styles as a sub-heading (short, larger or bold-and-larger than the
  body text, not an `h1`-`h6`) as a heading, one level below the page's next larger heading. A
  table whose rows each start with a short marker (✓, a number, a letter) or a small icon becomes
  a list (numbered markers give an ordered list), under its caption or title row.
- PDF looks like the page: original styling, paginated (A4 or Letter per system locale), text
  selectable, links clickable. Tables and code blocks wider than the page are fitted to the page
  width: code lines wrap, table cells wrap their text, and a table that is still too wide (content
  that cannot wrap) is scaled down. No text is cut at the right margin.
- Images, stylesheets (and their fonts and images), videos and documents are downloaded with the
  cookies and Referer a browser sends for a subresource of the page, recomputed at every redirect:
  - cookies: those of the browser that match the URL (domain, path, Secure, expiry); all of them
    when the URL is same-site with the page, all but `SameSite=Lax` and `SameSite=Strict` ones when
    it is cross-site (a cookie without SameSite is sent, as WebKit itself does; older macOS versions
    report `SameSite=None` as no SameSite). Same-site compares the hosts' last two labels (the whole host for an IP
    address), as there is no Public Suffix List: `a.example.co.uk` and `b.other.co.uk` count as
    same-site.
  - Referer: the page's full URL (without fragment) same-origin, its origin cross-origin, none from
    an https page to an http URL. The page's own Referrer-Policy is not known, so this is the default
    policy (`strict-origin-when-cross-origin`) for every page.
  - once a redirect goes from https to http, no cookies and no Referer; a redirect to anything but
    http(s) is not followed.

## Documents

- A document target is an `<iframe>`/`<frame>`/`<embed>`/`<object>`, or the page itself, whose
  http(s) URL names a supported file (by the extension of its path, in any case, ignoring query and
  fragment, or by its MIME type). Supported types: PDF (`.pdf`), Word (`.docx`), PowerPoint
  (`.pptx`), Excel (`.xlsx`, `.xls`) and Outlook messages (`.msg`). Legacy `.doc` and `.ppt` are
  not supported.
- Online viewers count as documents when the original's URL is in the viewer's URL: Office Online
  (`view.officeapps.live.com/op/embed.aspx?src=<url>` or `…/op/view.aspx?src=<url>`) and Google
  (`docs.google.com/viewer?url=<url>`, `docs.google.com/gview?url=<url>`,
  `drive.google.com/viewerng/viewer?url=<url>`). The original's URL is percent-decoded; a viewer
  inside a viewer is unwrapped once at most.
- A frame (or the page) that runs PDF.js (it defines `pdfjsLib` or `PDFViewerApplication`, read
  from the page's own scripts when picking starts) is a PDF viewer, and counts as a PDF document
  when its PDF's URL is found: the standard viewer's `PDFViewerApplication.url` (else `.baseUrl`),
  unless it is a `blob:` or `data:` URL; otherwise the PDF the frame itself fetched (a resource
  whose path ends in `.pdf`, loaded by `fetch`, `XMLHttpRequest` or the viewer itself; the largest
  when there are several). Custom viewers that draw each page into a `<canvas>` (e-book players,
  SCORM course packages) save nothing useful as a page, so this is how they are saved. A click
  anywhere in such a viewer picks its PDF; Return (or a click outside any target) picks it when it
  is the only PDF viewer the user can see, at any frame depth, and covers at least half of the
  view. A viewer whose PDF is not found is picked as a frame or page, as before.
- Nothing is scrolled. The app downloads the original with the browser's cookies and Referer for
  the page (see "Saving"), up to 500 MB, into a private temporary folder that is removed after the
  save, when the save panel is cancelled, and when the app quits (during the download or with the
  panel open), and checks that the file is what its type says (a PDF starts with
  `%PDF-`, `.docx`/`.pptx`/`.xlsx` are ZIP packages, `.xls`/`.msg` are OLE files).
- Output: a folder `Name/` with `Name.<ext>` (the original, unchanged, quarantined as a web
  download by PageCapture with its URL and the page's, like a browser download) and/or `Name.md` (its
  Markdown, made by the bundled MarkItDown in an isolated helper process). A scanned PDF (no text
  layer) is read with on-device text recognition.
- A document with no readable text keeps the original (even when only Markdown was ticked), and
  the result message says no text was found. When the Markdown cannot be made for another reason,
  the original is kept too and the message gives the reason (without file paths).
- When the original cannot be downloaded (a viewer without the original's URL, an HTTP error, a
  sign-in page instead of the file, larger than 500 MB, an unsupported type such as `.doc`), the
  app captures the frame as a page instead (scrolling, page save panel) and the result message
  says why.

## Videos

- During capture, each video in the target is found and its source recorded. Players that only
  load their stream on play are played briefly, muted, then paused and rewound; a player whose
  `<video>` only appears after clicking its play button gets that button clicked.
- Saved into `videos/` next to `images/` (`001-<name>.mp4`), downloaded with the browser's cookies
  and Referer for the video's frame (see "Saving"):
  - direct files (`.mp4`, `.webm`, `.mov`, …) as they are;
  - HLS streams (`.m3u8`): the app downloads the best variant (and its audio rendition) and the
    bundled ffmpeg joins it into `.mp4` without re-encoding; clear-key AES-128 is fine;
  - YouTube and Vimeo embeds: the bundled yt-dlp (with the bundled ffmpeg and Deno) downloads the
    best quality as `.mp4`, with the page as referer.
- DRM-protected videos (FairPlay, Widevine, SAMPLE-AES) and anything else that cannot be saved are
  never worked around: they keep a link to the original.
- Markdown and PDF show the video's preview image (its poster, else a frame taken by ffmpeg, else
  the site thumbnail) saved in `images/`, linking to the local `videos/<file>`; unsaved videos link
  to the original. The result message counts saved, failed and protected videos.
- Bundled tools live in `PageCapture.app/Contents/Helpers/` (ffmpeg and ffprobe built from source,
  LGPL, remux only; yt-dlp; Deno). yt-dlp runs from a working copy in
  `~/Library/Application Support/PageCapture/` so the menu item **Update Download Tools** can run
  its own updater without touching the signed app.
- The app also bundles a pinned Python with Microsoft MarkItDown (documents, no audio/video; the runtime makes no
  network calls on its own, and the app only ever passes it local files, though MarkItDown can fetch a
  URL if given one) in `PageCapture.app/Contents/Resources/markitdown`, with `Contents/Helpers/markitdown`
  a symlink to it. It writes the Markdown of every capture (above) and converts documents to Markdown
  (see "Documents").
- MarkItDown runs in isolated helper processes with no network and no access to the user's files.
  Scanned PDFs are read with on-device text recognition (macOS Vision, fast mode) in a separate isolated
  helper.

## Install

- Unsigned (ad-hoc signed) `.app` in a drag-to-Applications DMG, built by a script.
- First launch: right-click → Open to pass Gatekeeper.

## Stack

Swift Package Manager project (Swift, SwiftUI + AppKit, WebKit), macOS 14+. Logic that can be
tested without UI lives in a library target with XCTest/Swift Testing tests.

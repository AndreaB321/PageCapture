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
- the whole page.

## Shortcut and banner

A single shortcut, **⌘⇧S**, works while the app is frontmost:

1. Idle → press ⌘⇧S → **picker mode**. Banner: "Pick a frame, scrolling area or article… (Return = whole page, Esc = cancel)".
   The element under the mouse (frame, scrollable area or main article) is highlighted.
   Clicking a highlighted target picks it; clicking outside any target, or pressing Return,
   picks the whole page. Esc, or ⌘⇧S again, cancels back to idle.
2. Target picked → **capturing**. Banner: "Capturing…". The app auto-scrolls the target from the top
   to the bottom, collecting content in order as it loads (lazy images, infinite lists). Content
   already collected is kept even if the page later removes it (virtualised lists); duplicates are
   dropped. Collapsed content in the target (accordions, `<details>`) is expanded first and after
   each scroll step, so every panel appears after its header in both PDF and Markdown. Each tab of
   a tab widget is shown in turn, then the tab selected before is selected again; both exports show
   every tab panel under its tab's title, without the tab bar. Links that navigate, menus/popups and
   form submits are never clicked.
3. Capture ends when the bottom is reached and no more content loads, or when the user presses
   ⌘⇧S again (keeps what was collected). The banner disappears and the save dialog opens.

No banner while idle. The banner is an on-screen overlay clearly visible over the browser content.

## Saving

- A Finder save panel lets the user name the capture and tick any of three formats: **HTML**,
  **PDF**, **Markdown** (at least one). The ticked set is remembered for the next save.
- Output: a folder `Name/` containing `Name.html`, `Name.pdf` and/or `Name.md` (the same `Name`
  for each), plus `images/` holding the original image files (from `<img>`/`<picture>`; CSS
  backgrounds are out of scope).
- HTML is one self-contained file that looks like the page on screen: the captured content with
  the site's stylesheets inlined (their fonts and images embedded), images embedded, no scripts,
  readable at any window width, every tab and accordion panel shown under its title. Videos show
  their preview and link to `videos/<file>` (or to the original when not saved). Like the
  Markdown, it leaves out the site's header, navigation and footer, unless they hold most of the
  text. It has none of the PDF's print-only changes.
- Markdown references images by relative path `images/<file>`; links are kept as Markdown links
  with absolute URLs.
- Markdown writes text the page styles as a sub-heading (short, larger or bold-and-larger than the
  body text, not an `h1`-`h6`) as a heading, one level below the page's next larger heading. A
  table whose rows each start with a short marker (✓, a number, a letter) or a small icon becomes
  a list (numbered markers give an ordered list), under its caption or title row.
- PDF looks like the page: original styling, paginated (A4 or Letter per system locale), text
  selectable, links clickable.

## Videos

- During capture, each video in the target is found and its source recorded. Players that only
  load their stream on play are played briefly, muted, then paused and rewound; a player whose
  `<video>` only appears after clicking its play button gets that button clicked.
- Saved into `videos/` next to `images/` (`001-<name>.mp4`), downloaded with the browser's cookies:
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

## Install

- Unsigned (ad-hoc signed) `.app` in a drag-to-Applications DMG, built by a script.
- First launch: right-click → Open to pass Gatekeeper.

## Stack

Swift Package Manager project (Swift, SwiftUI + AppKit, WebKit), macOS 14+. Logic that can be
tested without UI lives in a library target with XCTest/Swift Testing tests.

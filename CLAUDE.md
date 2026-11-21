# PageCapture

macOS app (Swift 6, SwiftPM, SwiftUI + AppKit, WebKit, macOS 14+, Apple silicon) that captures a
scrolling webpage, or one frame or scrolling area of it, and saves it as HTML, PDF and Markdown.
`SPEC.md` is the behaviour contract; `README.md` is the user manual.

## Commands

| What | Command | Time |
|---|---|---|
| Build app and tests | `swift build --build-tests` | ~15 s, must show 0 warnings |
| Full suite | `swift test` | ~70 s |
| One suite | `swift test --filter MarkdownExporterTests` | seconds |
| Bundled tools (ffmpeg built from source, yt-dlp, Deno) | `scripts/fetch-tools.sh` | slow the first time |
| MarkItDown runtime only (Python + MarkItDown, no ffmpeg; needs `zstd`, `brew install zstd`) | `scripts/fetch-tools.sh markitdown` | ~1 min the first time, then a no-op |
| App and DMG | `scripts/make-dmg.sh` | runs fetch-tools first |

Without `build/tools`, `ToolsTests` and `VideoDownloaderTests` are skipped (29 tests): a green run
says "0 failures" with those skips. Run `scripts/fetch-tools.sh` before changing anything in
`Tools.swift` or `VideoDownloader.swift`, so those tests actually run.

## Layout

- `Sources/PageCaptureCore`: all logic that can be tested without UI.
  - `CaptureStateMachine`: the pure ⌘⇧S flow (events in, effects out). New flow states go here first.
  - `PageCaptureBridge`: connects the web view to the injected scripts in every frame.
  - `Resources/capture.js`: picker and collector, run in every frame. Large: read it by function.
  - `CaptureExporter`: the save pipeline; `HTMLExporter`, `PDFExporter`, `MarkdownExporter` render
    with `document.js`, `markdown.js` and `chrome.js` in an off-screen web view.
  - `VideoDownloader`, `Tools`: external processes (ffmpeg, yt-dlp, Deno).
  - `DocumentConverter`: one local file to Markdown with the bundled MarkItDown (pinned Python +
    MarkItDown, `Contents/Resources/markitdown`), on a private copy under `sandbox-exec` (`(deny
    default)`: reads only the runtime, its work directory and system libraries, writes only in its
    work directory, no network, no child processes); runs the `pagecapture-ocr` helper, under its
    own profile, on PDFs without text; no callers yet. Fixtures: `scripts/make-document-fixtures.sh`.
- `Sources/PageCaptureOCRKit`: `PDFTextRecognizer`, Vision OCR (`.fast`; the sandbox allows the GPU,
  not the Neural Engine) of image-only PDFs to Markdown (`hasTextLayer` tells scans apart). Used by
  the `pagecapture-ocr` helper, which `DocumentConverter` runs under its own sandbox profile.
- `Sources/PageCaptureOCR`: the `pagecapture-ocr` helper, run under `sandbox-exec`. Exit codes: 0 ok, 1 failed,
  2 usage, 3 unreadable, 4 no text. `--probe-*` flags exist in DEBUG builds only, for the sandbox tests.
- `Sources/PageCaptureUI`: windows and views; `CaptureController` performs the state machine's effects.
- `Sources/PageCapture`: the app entry point. `Sources/ManualShots`: manual screenshots, not shipped.

## Tests

- Page behaviour is tested against HTML fixtures in `Tests/PageCaptureCoreTests/Fixtures/`, served
  as `pctest://<host>/<file>` by `FixtureSchemeHandler` (different hosts are different origins).
  A new capture or export behaviour gets its own fixture page and a test that fails without the change.
- Video tests serve `Fixtures/video` through `FixtureURLProtocol`; `scripts/make-video-fixtures.sh`
  regenerates the media.

## Working rules

- A change of behaviour updates `SPEC.md` first, then tests, then code; user-visible changes also
  update `README.md` and `docs/manual/index.html` (its screenshots come from `swift run ManualShots`).
- Known limits are listed in README "Tips and limits"; remove an entry when it is fixed.
- The app version is `APP_VERSION` in `scripts/build-app.sh`; `make-source-bundle.sh` reads it from there.
- Tool versions and checksums are pinned in `scripts/tool-pins.sh`.
- Python trees in a signed .app go in Contents/Resources with precompiled unchecked-hash bytecode, never in Contents/Helpers.
- DRM-protected media is never worked around (SPEC "Videos").

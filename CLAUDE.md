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
- `Sources/PageCaptureUI`: windows and views; `CaptureController` performs the state machine's effects.
- `Sources/PageCapture`: the app entry point. `Sources/ManualShots`: manual screenshots, not shipped.

## Tests

- Page behaviour is tested against HTML fixtures in `Tests/PageCaptureCoreTests/Fixtures/`, served
  as `pctest://<host>/<file>` by `FixtureSchemeHandler` (different hosts are different origins).
  A new capture or export behaviour gets its own fixture page and a test that fails without the change.
- Video tests serve `Fixtures/video` through `FixtureURLProtocol`; `scripts/make-video-fixtures.sh`
  regenerates the media.
- WebKit throttles timers in the test window (pauses of ~1 s are common). Timing tests log event
  times inside the fixture page and assert on the gaps between them, never on wall-clock durations
  of a whole capture. When a timing test survives a deliberate break of the code it covers, log
  the fixture's event times before redesigning it.
- A fix's test must fail with the fix set aside: put the fix's own source lines in a patch file
  (`git diff <base> -- <paths> > .build/scratch/x.patch && git apply -R …`), run the test, then
  `git apply` it back and rebuild.

## Working rules

- A change of behaviour updates `SPEC.md` first, then tests, then code; user-visible changes also
  update `README.md` and `docs/manual/index.html` (its screenshots come from `swift run ManualShots`).
- Known limits are listed in README "Tips and limits"; remove an entry when it is fixed.
- The app version is `APP_VERSION` in `scripts/build-app.sh`; `make-source-bundle.sh` reads it from there.
- Tool versions and checksums are pinned in `scripts/tool-pins.sh`.
- DRM-protected media is never worked around (SPEC "Videos").

# Third-party notices

PageCapture's own code is under the MIT licence (see [LICENSE](LICENSE)). To save videos, the app
also ships four third-party programs in `PageCapture.app/Contents/Helpers/`: ffmpeg, ffprobe, yt-dlp
and Deno. PageCapture runs them as separate programs and does not link them into its own code.
Each one keeps its own licence, described below.

- **Licence texts**: in the app at `PageCapture.app/Contents/Resources/ThirdPartyNotices/`, with this
  file. `scripts/fetch-tools.sh` downloads them from upstream, pinned by SHA-256.
- **Corresponding source**: every GitHub release has `PageCapture-third-party-sources-<version>.tar`
  attached next to the DMG. `scripts/make-source-bundle.sh` builds it. Its `README.txt` and
  `SHA256SUMS` describe the contents.

All versions and checksums are pinned in `scripts/tool-pins.sh`.

## FFmpeg 9.0.2 (ffmpeg, ffprobe)

- **Upstream**: <https://ffmpeg.org>
- **Licence**: GNU Lesser General Public License version 2.1 or later. The build is configured
  without `--enable-gpl` and `--enable-nonfree` and contains no external libraries. It links only
  macOS's own zlib and system frameworks.
- **What PageCapture ships**: `ffmpeg` and `ffprobe` built by `scripts/fetch-tools.sh` from the
  unmodified source release <https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz>
  (SHA-256 `8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e`). They are built as a
  reduced feature set (remuxing and poster frames) and are ad-hoc code-signed.
- **Source**: the sources bundle contains `ffmpeg-9.0.2.tar.xz` and `ffmpeg-build.txt`, which has
  the exact configure command, build environment and compiler. `FFmpeg.txt` in the app repeats the
  configure line, and `ffmpeg -buildconf` prints it too.
- **Using your own FFmpeg**: replace `Contents/Helpers/ffmpeg` and `Contents/Helpers/ffprobe` with
  your own builds, then re-sign the app (for example `codesign --force -s - PageCapture.app`), since
  changing the bundle breaks its signature.
- **Texts**: `FFmpeg-COPYING.LGPLv2.1.txt`, `FFmpeg.txt`.

## yt-dlp 2026.10.26 (yt-dlp_macos)

- **Upstream**: <https://github.com/yt-dlp/yt-dlp>
- **What PageCapture ships**: the official `yt-dlp_macos` release executable, unmodified
  (SHA-256 `0f922c15ccc0b83eefa1c8bc9104e434318c4bf16e408e1ee93b7745a6efe0aa`, as listed in the
  release's `SHA2-256SUMS`). It is a PyInstaller executable: yt-dlp plus a Python interpreter and
  Python packages.
- **Licence**: yt-dlp's own code is under the Unlicense. Its README says that the PyInstaller-bundled
  executables include GPLv3+ code, so the combined executable is licensed under the
  **GNU General Public License version 3 or later**. Each bundled component also keeps its own
  licence.
- **What is inside** (from yt-dlp's `THIRD_PARTY_LICENSES.txt` and `bundle/requirements/macos*.txt`
  at the release tag):

  | Component | Version | Licence |
  |---|---|---|
  | Python, with bzip2, libffi, OpenSSL 3, SQLite, liblzma, mpdecimal, zlib, Expat, ncurses | 3.14.7 | PSF-2.0 (Python); bzip2-1.0.6, MIT, Apache-2.0, public domain, 0BSD, BSD-2-Clause, zlib, MIT, X11-style |
  | PyInstaller bootloader | 6.22.0 | GPL-2.0-or-later with the Bootloader Exception |
  | mutagen | 1.48.1 | GPL-2.0-or-later |
  | certifi | 2026.10.23 | MPL-2.0 |
  | requests | 2.34.2 | Apache-2.0 |
  | urllib3 | 2.8.0 | MIT |
  | charset-normalizer | 3.5.2 | MIT |
  | idna | 3.20 | BSD-3-Clause |
  | brotli | 1.2.1 | MIT |
  | websockets | 17.3 | BSD-3-Clause |
  | pycryptodomex | 3.24.1 | BSD-2-Clause and public domain |
  | yt-dlp-ejs, with Meriyah and Astring | 0.8.0 | Unlicense; ISC; MIT |
  | curl_cffi, with curl-impersonate, curl, BoringSSL, nghttp2, ngtcp2, nghttp3, zstd | 0.17.0 | MIT; MIT, curl, Apache-2.0, MIT, MIT, MIT, BSD-3-Clause |
  | cffi | 2.1.1 | MIT-0 |
  | pycparser | 3.11 | BSD-3-Clause |

  `THIRD_PARTY_LICENSES.txt` has the full licence text of each component. It covers every yt-dlp
  build, so some of its entries are not in `yt-dlp_macos`: those marked as Windows-only or
  Linux-only, and Tornado and httpx.
- **Source**: the sources bundle contains yt-dlp's release source tarball `yt-dlp.tar.gz` (its
  SHA-256 is checked against the release's `SHA2-256SUMS`). It also contains GitHub's archive of the
  `2026.10.26` tag, which includes the PyInstaller build script (`bundle/pyinstaller.py`), the
  hash-pinned requirements and the release workflow (`.github/workflows/build.yml`). The sources of
  Python and of the packages above, at the listed versions, are published by those projects
  (<https://www.python.org/downloads/>, <https://pypi.org>). yt-dlp's `THIRD_PARTY_LICENSES.txt`
  says its maintainers will provide them on request if they cannot be obtained.
- **Texts**: `yt-dlp-LICENSE.txt` (Unlicense), `yt-dlp-THIRD_PARTY_LICENSES.txt` (all bundled
  components, including Python's PSF licence and mutagen's GPL-2.0), `GPL-3.0.txt`.

## Deno 2.9.8

- **Upstream**: <https://github.com/denoland/deno>
- **What PageCapture ships**: the official `deno` executable from `deno-aarch64-apple-darwin.zip`,
  unmodified (zip SHA-256 `9f0bf660393da2eaff044cdc7444cb08c73f235849b61d224d825a194ce7c98e`).
- **Licence**: MIT.
- **What is inside**:
  - V8, the JavaScript engine (BSD-3-Clause). It comes through the `v8` crate 150.4.0
    (denoland/rusty_v8, MIT) at V8 commit `ac1e23989121713ca642f6650b34deff7b686896`. V8's licence
    file also names the externally maintained code in V8 and its licences.
  - ICU (Unicode License v3), at commit `ee5f27adc28bd3f15b2c293f726d14d2e336cbd5` of Chromium's ICU.
  - Many Rust crates from crates.io under their own licences, mostly MIT and/or Apache-2.0. The
    `Cargo.lock` in Deno's source lists them. The Deno project does not publish a third-party notices
    file for its release executables.
- **Source**: the MIT, BSD-3-Clause and Unicode licences do not require distributing source, so the
  sources bundle does not contain Deno. Deno's source for this version is published as
  `deno_src.tar.gz` at <https://github.com/denoland/deno/releases/tag/v2.9.8>.
- **Texts**: `Deno-LICENSE.md`, `V8-LICENSE.txt`, `ICU-LICENSE.txt`.

# Third-party notices

PageCapture's own code is under the MIT licence (see [LICENSE](LICENSE)). To save videos, the app
also ships third-party programs in `PageCapture.app/Contents/Helpers/`: ffmpeg, ffprobe, yt-dlp,
Deno and a Python runtime with MarkItDown (for Markdown conversion of documents). PageCapture runs
them as separate programs and does not link them into its own code.
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

## MarkItDown 0.1.9 and its Python 3.13.18 runtime (markitdown)

- **Upstream**: <https://github.com/microsoft/markitdown> (MIT), running on CPython from
  python-build-standalone <https://github.com/astral-sh/python-build-standalone>.
- **What PageCapture ships**: `Contents/Helpers/markitdown`, a relocatable CPython 3.13.18
  (python-build-standalone release 20261110, `install_only_stripped` build for aarch64, SHA-256
  `7a2384641584ab9984221fcb0fc9265df465922af71be71410529e2a9c3f0540`) with MarkItDown and the
  Python packages it needs, installed from the official PyPI wheels, unmodified except for compiled
  bytecode (every module is precompiled) and an ad-hoc re-signature of their native libraries. The
  37 wheels and their SHA-256s are listed in `scripts/markitdown-requirements.txt`. pip, IDLE, Tk and the packages'
  test suites are left out. It runs as a separate process.
- **Licence**: MarkItDown is under the MIT licence. Python is under the PSF licence 2.0. Each
  component keeps its own licence, as listed below.
- **What is inside Python** (OpenSSL, SQLite, expat and mpdecimal versions are those the runtime reports; bzip2,
  libffi and liblzma versions are read from the static libraries of this build; licence texts are
  python-build-standalone's `licenses/` for it):

  | Component | Version | Licence |
  |---|---|---|
  | Python | 3.13.18 | PSF-2.0 |
  | OpenSSL | 3.5.9 | Apache-2.0 |
  | SQLite | 3.53.1 | public domain |
  | expat | 2.10.0 | MIT |
  | mpdecimal | 4.0.0 | BSD-2-Clause |
  | bzip2 | 1.0.8 | bzip2-1.0.6 |
  | libffi | 3.8.0 | MIT |
  | liblzma | 5.8.4 | 0BSD / public domain |

- **What is inside the packages**: 
  the 37 wheels (MarkItDown included) by licence, as the wheels' metadata state it:

  | Licence | Packages |
  |---|---|
  | MIT | markitdown 0.1.9, beautifulsoup4 4.15.0, charset-normalizer 3.5.2, et_xmlfile 2.0.0, markdownify 1.2.4, onnxruntime 1.32.0, openpyxl 3.1.5, pdfminer.six 20260107, pdfplumber 0.11.11, python-pptx 1.0.2, soupsieve 4.1.3, urllib3 2.8.0 |
  | MIT-0 | cffi 2.1.1 |
  | MIT-CMU | pillow 13.0.0 |
  | BSD-2-Clause | mammoth 1.13.0, xlsxwriter 3.3.3, cobble 0.1.4 (BSD-2-Clause per its README; the wheel has no licence file) |
  | BSD-3-Clause | click 8.5.1, idna 3.20, lxml 6.1.3, olefile 0.47 (BSD), pandas 3.1.1, protobuf 7.36.2, pycparser 3.12, python-dateutil 4.0.0 (BSD-3-Clause; also Apache-2.0 per its licence file), xlrd 2.0.2 (BSD), numpy 2.5.5 (with 0BSD, MIT, Zlib, CC0-1.0 parts) |
  | Apache-2.0 | flatbuffers 25.12.19, magika 1.0.3, requests 2.34.2, tzdata 2026.6 |
  | Apache-2.0 or BSD-3-Clause | cryptography 50.0.2 |
  | Apache-2.0 or BSD-2-Clause | packaging 26.3 |
  | BSD-3-Clause and Apache-2.0 (with dependency licences) | pypdfium2 5.15.2 |
  | PSF-2.0 | typing_extensions 4.16.0, defusedxml 0.7.1 |
  | MPL-2.0 | certifi 2026.11.20 |

  Each wheel's own licence text is in `MarkItDown-<component>-<version>.txt`.
- **C libraries in lxml**: the lxml wheel (`lxml/etree`, `lxml/objectify`) statically links GNU libiconv
  1.18, under the **GNU Lesser General Public License version 2.1**, and also libxml2 2.14.6 and
  libxslt 1.1.43 (MIT) and zlib 1.3.2 (zlib licence). The sources bundle contains `libiconv-1.18.tar.gz`
  (from <https://ftp.gnu.org/pub/gnu/libiconv/>), `libxml2-2.14.6.tar.xz`, `libxslt-1.1.43.tar.xz`
  (from <https://download.gnome.org/sources/>), `zlib-1.3.2.tar.gz` (from <https://zlib.net/fossils/>),
  all unmodified, and `lxml-6.1.3.tar.gz`, whose `buildlibxml.py` builds lxml's static libraries.
- **Using your own libiconv (or libxml2, libxslt, zlib)**: unpack the sdist from the sources bundle
  and the tarballs into one directory, replacing the one you changed with yours, then build lxml from
  inside the sdist, without network:

  ```sh
  python3 setup.py build_ext --static-deps --download-dir <directory with the four tarballs> \
      --libxml2-version 2.14.6 --libxslt-version 1.1.43 --zlib-version 1.3.2 --libiconv-version 1.18
  ```

  Set the `--*-version` options to the versions of your own tarballs. Then replace
  `Contents/Resources/markitdown/lib/python3.13/site-packages/lxml` (`Contents/Helpers/markitdown` is
  a symlink to it) with the built package, and precompile it, because the runtime's bytecode is
  checked by hash never and the old bytecode would otherwise stay in use:

  ```sh
  python3 -I -m compileall -q -f --invalidation-mode unchecked-hash <site-packages>/lxml
  ```

  Last, re-sign: `codesign --force -s -` on each changed `.so` file, then on `PageCapture.app`.
- **Source**: the sources bundle contains libiconv, libxml2, libxslt, zlib and lxml as above. The
  sources of Python (at python-build-standalone's pinned versions) and of the other packages are
  published by those projects (<https://www.python.org/downloads/>, <https://pypi.org>).
- **Texts**: `MarkItDown.txt` (what is shipped), `MarkItDown-<component>-<version>.txt` for every
  component, `LGPL-2.1.txt`.

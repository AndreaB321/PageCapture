#!/bin/bash
# Produces the tools bundled in PageCapture.app/Contents/Helpers (arm64):
#   build/tools/{ffmpeg,ffprobe}  built from the official FFmpeg source tarball, static, LGPL,
#                                 remux plus poster-frame extraction only, no network protocols
#   build/tools/yt-dlp            the official yt-dlp_macos release binary
#   build/tools/deno              the official deno-aarch64-apple-darwin release binary
#   build/tools/markitdown/       CPython (python-build-standalone) with MarkItDown and its
#                                 packages, for documents to Markdown; bin/python3 -m markitdown
# and their licence texts in build/notices/. Pins and the download helper are in tool-pins.sh.
# Every download is pinned and checked against its SHA-256. Finished steps are skipped on reruns.
# `scripts/fetch-tools.sh markitdown` produces only the MarkItDown runtime (what CI uses).
set -euo pipefail
cd "$(dirname "$0")/.."

case "${1:-all}" in
    all | markitdown) ONLY="${1:-all}" ;;
    *) echo "usage: $0 [markitdown]" >&2; exit 2 ;;
esac

. scripts/tool-pins.sh

TOOLS=build/tools
NOTICES=build/notices
# The exact FFmpeg build recipe, for the corresponding-source bundle (make-source-bundle.sh).
FFMPEG_BUILD_TXT="$CACHE/ffmpeg-build.txt"
mkdir -p "$CACHE" "$TOOLS" "$NOTICES"

# --- MarkItDown ------------------------------------------------------------------------------
# Converts PDF, Word, PowerPoint, Excel, Outlook .msg and HTML files to Markdown, run as a child
# process. Only the extras pdf, docx, pptx, xlsx, xls and outlook are installed: no audio, YouTube
# or Azure ones. Every wheel is pinned by hash in markitdown-requirements.txt; no sdists.
MD_REQS=scripts/markitdown-requirements.txt
MD_PY="${PBS_PYTHON_VERSION%.*}" # 3.13
MD_STAMP="$CACHE/markitdown.stamp"
MD_TREE="$CACHE/markitdown.tree" # digest of the finished tree (md_tree_digest)
# The stamp covers the recipe (this section of this script), every pin the section uses and the
# requirements file, so a change to any of them rebuilds.
MD_RECIPE="$(sed -n '/^# --- MarkItDown ---/,/^# GNU libiconv, inside lxml\./p' scripts/fetch-tools.sh | shasum -a 256 | cut -d' ' -f1)"
MD_WANT="$PBS_NAME $PBS_SHA256 $PBS_FULL_SHA256 $(shasum -a 256 "$MD_REQS" | cut -d' ' -f1) $MD_RECIPE"
MD_WANT+=" $MARKITDOWN_VERSION $LXML_VERSION $LIBICONV_VERSION $MAGIKA_VERSION $FLATBUFFERS_VERSION $COBBLE_VERSION"
MD_WANT+=" $MARKITDOWN_LICENSE_SHA256 $MAGIKA_LICENSE_SHA256 $FLATBUFFERS_LICENSE_SHA256 $COBBLE_README_SHA256"
MD_PY_NOTICE="$NOTICES/MarkItDown-Python-$PBS_PYTHON_VERSION.txt"

# Pins and the requirements file must agree; checked on every run, also when up to date.
for pin in "markitdown==$MARKITDOWN_VERSION" "lxml==$LXML_VERSION" "magika==$MAGIKA_VERSION" \
    "flatbuffers==$FLATBUFFERS_VERSION" "cobble==$COBBLE_VERSION"; do
    grep -qxF "$pin \\" "$MD_REQS" || { echo "$MD_REQS has no $pin (tool-pins.sh)" >&2; exit 1; }
done
# lxml's wheel links GNU libiconv statically; the sources bundle carries LIBICONV_VERSION.
check_libiconv() {
    local iconv
    iconv="$("$1/bin/python3" -I -B -c 'import ctypes, lxml.etree as e
v = ctypes.c_int.in_dll(ctypes.CDLL(e.__file__), "_libiconv_version").value
print(f"{v >> 8}.{v & 0xff}")')"
    [[ "$iconv" == "$LIBICONV_VERSION" ]] \
        || { echo "lxml links libiconv $iconv, tool-pins.sh says $LIBICONV_VERSION" >&2; exit 1; }
}
# Every distribution in the tree (pip excepted) has its notice.
check_md_notices() {
    local dist name
    for dist in "$1"/lib/python"$MD_PY"/site-packages/*.dist-info; do
        name="$(basename "$dist" .dist-info)"
        [[ "$name" == pip-* || -s "$NOTICES/MarkItDown-$name.txt" ]] \
            || { echo "No licence text for $name: add one to fetch-tools.sh" >&2; exit 1; }
    done
}

if [[ -x "$TOOLS/markitdown/bin/python3" && -f "$MD_STAMP" && -f "$MD_TREE" && -f "$MD_PY_NOTICE" ]] \
    && [[ "$(cat "$MD_STAMP")" == "$MD_WANT" ]]; then
    [[ "$(md_tree_digest "$TOOLS/markitdown")" == "$(cat "$MD_TREE")" ]] \
        || { echo "$TOOLS/markitdown changed since it was built; delete it and rerun fetch-tools.sh markitdown" >&2; exit 1; }
    check_md_notices "$TOOLS/markitdown"
    check_libiconv "$TOOLS/markitdown"
    echo "markitdown $MARKITDOWN_VERSION (Python $PBS_PYTHON_VERSION): up to date"
else
    command -v zstd >/dev/null || { echo "zstd is needed to unpack Python's licences (brew install zstd)" >&2; exit 1; }
    PY_TGZ="$PBS_NAME-install_only_stripped.tar.gz"
    PY_FULL="$PBS_NAME-pgo+lto-full.tar.zst"
    check_pbs_published "$PBS_SHA256" "$PY_TGZ"
    check_pbs_published "$PBS_FULL_SHA256" "$PY_FULL"
    fetch "$PBS_URL/${PY_TGZ//+/%2B}" "$CACHE/$PY_TGZ" "$PBS_SHA256"
    fetch "$PBS_URL/${PY_FULL//+/%2B}" "$CACHE/$PY_FULL" "$PBS_FULL_SHA256"

    WORK="$CACHE/markitdown-work"
    rm -rf "$WORK" "$TOOLS/markitdown" "$MD_STAMP" "$MD_TREE"
    mkdir -p "$WORK/full"
    tar -xzf "$CACHE/$PY_TGZ" -C "$WORK"
    zstd -dcq "$CACHE/$PY_FULL" | tar -xf - -C "$WORK/full" python/licenses
    P="$WORK/python"
    LIB="$P/lib/python$MD_PY"
    SITE="$LIB/site-packages"

    echo "Installing markitdown $MARKITDOWN_VERSION into Python $PBS_PYTHON_VERSION"
    # The wheels for macOS 14 arm64 (the app's minimum), kept in the cache; pip checks each hash
    # while downloading and again while installing.
    PIP=("$P/bin/python3" -I -m pip --isolated --disable-pip-version-check --no-cache-dir --quiet)
    "${PIP[@]}" download --require-hashes --no-deps --only-binary=:all: \
        --platform macosx_14_0_arm64 --python-version "$MD_PY" --implementation cp \
        --abi "cp${MD_PY/./}" -d "$CACHE/markitdown-wheels" -r "$MD_REQS"
    "${PIP[@]}" install --require-hashes --no-deps --only-binary=:all: --no-compile \
        --no-index --find-links "$CACHE/markitdown-wheels" -r "$MD_REQS"

    check_libiconv "$P"

    # One notice per bundled distribution. Python: CPython and the libraries built into it (the
    # interpreter uses macOS's own zlib, libedit and ncurses).
    rm -f "$NOTICES"/MarkItDown-*
    {
        echo "Python $PBS_PYTHON_VERSION, python-build-standalone $PBS_RELEASE ($PY_TGZ)"
        echo "in PageCapture.app/Contents/Helpers/markitdown, and the libraries built into it."
        for lic in cpython bzip2 expat libffi liblzma mpdecimal openssl-3 sqlite libuuid; do
            printf '\n===== %s =====\n\n' "LICENSE.$lic.txt"
            cat "$WORK/full/python/licenses/LICENSE.$lic.txt"
        done
    } >"$MD_PY_NOTICE"
    # Each wheel: the licence files in its .dist-info (with those of the libraries it bundles).
    for dist in "$SITE"/*.dist-info; do
        name="$(basename "$dist" .dist-info)"
        [[ "$name" == pip-* ]] && continue
        files="$(find "$dist" -type f \( -path '*/licenses/*' -o -iname 'LICEN[CS]E*' \
            -o -iname 'COPYING*' -o -iname 'NOTICE*' -o -iname 'AUTHORS*' \) | sort)"
        [[ -n "$files" ]] || continue
        while read -r f; do
            printf '===== %s =====\n\n' "${f#"$dist"/}"
            cat "$f"
            echo
        done <<<"$files" >"$NOTICES/MarkItDown-$name.txt"
    done
    # onnxruntime keeps its licence and third-party notices in the package.
    for f in LICENSE ThirdPartyNotices.txt; do
        printf '===== onnxruntime/%s =====\n\n' "$f"
        cat "$SITE/onnxruntime/$f"
        echo
    done >>"$NOTICES/MarkItDown-onnxruntime-$(sed -n 's/^onnxruntime==\([^ ]*\) .*/\1/p' "$MD_REQS").txt"
    # Wheels without a licence file: the text from the project's repository at the release tag.
    fetch "https://raw.githubusercontent.com/microsoft/markitdown/v$MARKITDOWN_VERSION/LICENSE" \
        "$NOTICES/MarkItDown-markitdown-$MARKITDOWN_VERSION.txt" "$MARKITDOWN_LICENSE_SHA256"
    fetch "https://raw.githubusercontent.com/google/magika/python-v$MAGIKA_VERSION/LICENSE" \
        "$NOTICES/MarkItDown-magika-$MAGIKA_VERSION.txt" "$MAGIKA_LICENSE_SHA256"
    fetch "https://raw.githubusercontent.com/google/flatbuffers/v$FLATBUFFERS_VERSION/LICENSE" \
        "$NOTICES/MarkItDown-flatbuffers-$FLATBUFFERS_VERSION.txt" "$FLATBUFFERS_LICENSE_SHA256"
    fetch "https://raw.githubusercontent.com/mwilliamson/python-cobble/$COBBLE_VERSION/README.rst" \
        "$NOTICES/MarkItDown-cobble-$COBBLE_VERSION.txt" "$COBBLE_README_SHA256"
    check_md_notices "$P"

    # Leave out what converting documents never uses: pip, IDLE, Tk, test suites. bin/ keeps only
    # the interpreter: the packages' entry-point scripts hard-code this build directory.
    rm -rf "$SITE"/pip "$SITE"/pip-*.dist-info "$LIB"/ensurepip "$LIB"/idlelib "$LIB"/tkinter \
        "$LIB"/turtledemo "$LIB"/turtle.py "$LIB"/lib-dynload/_tkinter.* \
        "$P"/lib/libtcl* "$P"/lib/tcl9* "$P"/lib/tk9* "$P"/lib/itcl* "$P"/lib/thread* \
        "$P"/include "$P"/share
    find "$SITE" -type d -name tests -prune -exec rm -rf {} +
    find "$P/bin" -mindepth 1 ! -name python ! -name python3 ! -name "python$MD_PY" -delete
    # Bytecode for every module, checked by hash never: Python then never writes __pycache__ into
    # the signed app, and starts in a third of the time. olefile2.py is Python 2 code that
    # olefile never imports.
    find "$P" -type d -name __pycache__ -prune -exec rm -rf {} +
    "$P/bin/python3" -I -m compileall -q -f -j0 --invalidation-mode unchecked-hash \
        -x 'olefile/olefile2\.py$' "$LIB" >/dev/null

    "$P/bin/python3" -I -c '
import importlib.util as u
import markitdown, pdfminer, pdfplumber, mammoth, pptx, openpyxl, xlrd, olefile, magika
markitdown.MarkItDown()
extra = [m for m in ["pydub", "speech_recognition", "youtube_transcript_api", "azure"] if u.find_spec(m)]
assert not extra, f"excluded packages installed: {extra}"'
    mv "$P" "$TOOLS/markitdown"
    rm -rf "$WORK"
    md_tree_digest "$TOOLS/markitdown" >"$MD_TREE"
    echo "$MD_WANT" >"$MD_STAMP"
fi
# GNU libiconv, inside lxml.
fetch "https://www.gnu.org/licenses/old-licenses/lgpl-2.1.txt" "$NOTICES/LGPL-2.1.txt" "$LGPL21_SHA256"

cat >"$NOTICES/MarkItDown.txt" <<EOF
MarkItDown $MARKITDOWN_VERSION and the Python it runs on

PageCapture.app/Contents/Helpers/markitdown is CPython $PBS_PYTHON_VERSION from
python-build-standalone release $PBS_RELEASE (https://github.com/astral-sh/python-build-standalone),
file $PBS_NAME-install_only_stripped.tar.gz (SHA-256 $PBS_SHA256),
with Microsoft MarkItDown $MARKITDOWN_VERSION (MIT, https://github.com/microsoft/markitdown) and the
Python packages it needs installed from the official PyPI wheels, unmodified except for compiled
bytecode (every module is precompiled) and an ad-hoc re-signature of their native libraries. The list
of wheels and their SHA-256s is scripts/markitdown-requirements.txt in the PageCapture repository.
pip, IDLE, Tk and the packages' test suites are left out.

Each component's licence is in MarkItDown-<component>-<version>.txt next to this file
(MarkItDown-Python-$PBS_PYTHON_VERSION.txt for Python and the libraries built into it).

The lxml wheel (lxml/etree and lxml/objectify) contains GNU libiconv $LIBICONV_VERSION, linked
statically, under the GNU Lesser General Public License version 2.1 (LGPL-2.1.txt), and also libxml2
$LIBXML2_VERSION and libxslt $LIBXSLT_VERSION (MIT) and zlib $ZLIB_VERSION (zlib licence). The PageCapture
sources bundle has their tarballs and lxml-$LXML_VERSION.tar.gz, whose buildlibxml.py builds lxml against
them. To use a modified one, build lxml from that sdist with
  python3 setup.py build_ext --static-deps --download-dir <directory with the tarballs> \\
    --libxml2-version V --libxslt-version V --zlib-version V --libiconv-version V
and replace Contents/Resources/markitdown/lib/python$MD_PY/site-packages/lxml with the result
(Contents/Helpers/markitdown is a symlink to it). Precompile it with
  python3 -I -m compileall -q -f --invalidation-mode unchecked-hash <site-packages>/lxml
then re-sign: codesign --force -s - on each changed .so file, then on PageCapture.app.
EOF

if [[ "$ONLY" == markitdown ]]; then
    echo "MarkItDown ready in $TOOLS/markitdown"
    exit 0
fi

# --- FFmpeg ----------------------------------------------------------------------------------
# Only what PageCapture needs: joining local HLS (.ts or fMP4 segments, clear-key AES-128 through
# the crypto protocol) into .mp4, what yt-dlp needs to merge and probe (mp4/m4a/webm in, mp4/mkv
# out), and one PNG frame from h264/hevc/vp9/vp8 video for posters. Everything is LGPL; no
# external libraries except the system zlib (needed by the PNG encoder).
FFMPEG_CONFIG=(
    --disable-everything --disable-autodetect --disable-network
    --disable-doc --disable-ffplay --disable-avdevice --disable-debug
    --enable-static --disable-shared --enable-zlib
    --extra-cflags=-mmacosx-version-min=14.0 --extra-ldflags=-mmacosx-version-min=14.0
    --enable-protocol=file,pipe,crypto
    --enable-demuxer=hls,mpegts,mov,matroska,aac,mp3,ac3,eac3,ogg,flac,wav,concat,ffmetadata
    --enable-muxer=mp4,mov,ipod,matroska,webm,image2,ffmetadata,null
    --enable-parser=h264,hevc,vp8,vp9,av1,aac,aac_latm,mpegaudio,ac3,opus,vorbis,flac
    --enable-bsf=aac_adtstoasc,h264_mp4toannexb,hevc_mp4toannexb,extract_extradata,vp9_superframe,vp9_superframe_split,setts
    --enable-decoder=h264,hevc,vp8,vp9,aac,mp3float,opus,vorbis,flac
    --enable-encoder=png
    --enable-filter=scale,format,null,anull,aformat,aresample,thumbnail,select
)
FFMPEG_STAMP="$CACHE/ffmpeg.stamp"
FFMPEG_WANT="$FFMPEG_VERSION ${FFMPEG_CONFIG[*]}"

if [[ -x "$TOOLS/ffmpeg" && -x "$TOOLS/ffprobe" && -f "$FFMPEG_STAMP" && -f "$FFMPEG_BUILD_TXT" ]] \
    && [[ "$(cat "$FFMPEG_STAMP")" == "$FFMPEG_WANT" ]]; then
    echo "ffmpeg $FFMPEG_VERSION: up to date"
else
    TARBALL="$CACHE/ffmpeg-$FFMPEG_VERSION.tar.xz"
    fetch "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" "$TARBALL" "$FFMPEG_SHA256"
    SRC="$CACHE/ffmpeg-$FFMPEG_VERSION"
    rm -rf "$SRC"
    tar -xf "$TARBALL" -C "$CACHE"
    echo "Building ffmpeg $FFMPEG_VERSION (log: $SRC/build.log)"
    # A clean environment keeps Homebrew's compilers, headers and pkg-config out of the build.
    BUILD_ENV=(env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin 'HOME=$HOME')
    JOBS="$(sysctl -n hw.ncpu)"
    (
        cd "$SRC"
        env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" \
            ./configure "${FFMPEG_CONFIG[@]}" >build.log 2>&1
        env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" \
            make -j"$JOBS" ffmpeg ffprobe >>build.log 2>&1
    ) || { tail -30 "$SRC/build.log" >&2; exit 1; }
    cp "$SRC/ffmpeg" "$SRC/ffprobe" "$TOOLS/"
    {
        echo "How the ffmpeg and ffprobe in PageCapture.app/Contents/Helpers were built"
        echo
        echo "Source: ffmpeg-$FFMPEG_VERSION.tar.xz, unmodified"
        echo "  https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"
        echo "  SHA-256 $FFMPEG_SHA256"
        echo "Built on: macOS $(sw_vers -productVersion) $(uname -m), Xcode SDK $(xcrun --show-sdk-version)"
        echo "Compiler: $(/usr/bin/cc --version | head -1)"
        echo
        echo "Commands, run in the unpacked ffmpeg-$FFMPEG_VERSION directory (a clean environment"
        echo "keeps Homebrew's compilers, headers and pkg-config out of the build):"
        echo
        echo "  ${BUILD_ENV[*]} ./configure ${FFMPEG_CONFIG[*]}"
        echo "  ${BUILD_ENV[*]} make -j$JOBS ffmpeg ffprobe"
        echo
        echo "The resulting ffmpeg and ffprobe are copied into Contents/Helpers unchanged except for an"
        echo "ad-hoc code signature (codesign --force -s -, scripts/build-app.sh). The build is static and"
        echo "links only the system zlib and system frameworks. The scripts that do this are"
        echo "scripts/fetch-tools.sh and scripts/build-app.sh in the PageCapture repository."
    } >"$FFMPEG_BUILD_TXT"
    cp "$SRC/COPYING.LGPLv2.1" "$NOTICES/FFmpeg-COPYING.LGPLv2.1.txt"
    echo "$FFMPEG_WANT" >"$FFMPEG_STAMP"
fi

cat >"$NOTICES/FFmpeg.txt" <<EOF
FFmpeg $FFMPEG_VERSION

PageCapture bundles the ffmpeg and ffprobe programs from FFmpeg (https://ffmpeg.org), built
without modification from the official source release:
https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz
(SHA-256 $FFMPEG_SHA256)

FFmpeg is licensed under the GNU Lesser General Public License version 2.1 or later
(see FFmpeg-COPYING.LGPLv2.1.txt). This build uses no GPL or non-free parts. It was configured with:
${FFMPEG_CONFIG[*]}

\`ffmpeg -buildconf\` prints the same configuration. To use a different FFmpeg, replace
Contents/Helpers/ffmpeg and Contents/Helpers/ffprobe with your own build.
EOF

# --- yt-dlp ----------------------------------------------------------------------------------
if [[ -x "$TOOLS/yt-dlp" ]] && [[ "$(shasum -a 256 "$TOOLS/yt-dlp" | cut -d' ' -f1)" == "$YTDLP_SHA256" ]]; then
    echo "yt-dlp $YTDLP_VERSION: up to date"
else
    # The pinned hash must also be the one the release publishes in SHA2-256SUMS.
    check_ytdlp_published "$YTDLP_SHA256" yt-dlp_macos
    fetch "$YTDLP_RELEASE/yt-dlp_macos" "$CACHE/yt-dlp_macos-$YTDLP_VERSION" "$YTDLP_SHA256"
    cp "$CACHE/yt-dlp_macos-$YTDLP_VERSION" "$TOOLS/yt-dlp"
    chmod 755 "$TOOLS/yt-dlp"
fi
fetch "https://raw.githubusercontent.com/yt-dlp/yt-dlp/$YTDLP_VERSION/LICENSE" \
    "$NOTICES/yt-dlp-LICENSE.txt" "$YTDLP_LICENSE_SHA256"
# The licences of what the yt-dlp_macos executable bundles (Python and its packages); the combined
# executable is GPLv3+, so the GPL text goes along.
fetch "https://raw.githubusercontent.com/yt-dlp/yt-dlp/$YTDLP_VERSION/THIRD_PARTY_LICENSES.txt" \
    "$NOTICES/yt-dlp-THIRD_PARTY_LICENSES.txt" "$YTDLP_THIRD_PARTY_SHA256"
fetch "https://www.gnu.org/licenses/gpl-3.0.txt" "$NOTICES/GPL-3.0.txt" "$GPL3_SHA256"

# --- Deno ------------------------------------------------------------------------------------
DENO_STAMP="$CACHE/deno.stamp"
if [[ -x "$TOOLS/deno" && -f "$DENO_STAMP" ]] && [[ "$(cat "$DENO_STAMP")" == "$DENO_VERSION" ]]; then
    echo "deno $DENO_VERSION: up to date"
else
    DENO_ZIP="$CACHE/deno-$DENO_VERSION-aarch64-apple-darwin.zip"
    fetch "https://github.com/denoland/deno/releases/download/v$DENO_VERSION/deno-aarch64-apple-darwin.zip" \
        "$DENO_ZIP" "$DENO_SHA256"
    rm -rf "$CACHE/deno-unzip"
    mkdir "$CACHE/deno-unzip"
    unzip -q "$DENO_ZIP" -d "$CACHE/deno-unzip"
    cp "$CACHE/deno-unzip/deno" "$TOOLS/deno"
    chmod 755 "$TOOLS/deno"
    rm -rf "$CACHE/deno-unzip"
    echo "$DENO_VERSION" >"$DENO_STAMP"
fi
fetch "https://raw.githubusercontent.com/denoland/deno/v$DENO_VERSION/LICENSE.md" \
    "$NOTICES/Deno-LICENSE.md" "$DENO_LICENSE_SHA256"
# Deno publishes no third-party notices for its binary; it embeds V8 and ICU.
fetch "https://raw.githubusercontent.com/denoland/v8/$V8_COMMIT/LICENSE" \
    "$NOTICES/V8-LICENSE.txt" "$V8_LICENSE_SHA256"
fetch_base64 "https://chromium.googlesource.com/chromium/deps/icu.git/+/$ICU_COMMIT/LICENSE?format=TEXT" \
    "$NOTICES/ICU-LICENSE.txt" "$ICU_LICENSE_SHA256"

echo "Tools ready in $TOOLS"

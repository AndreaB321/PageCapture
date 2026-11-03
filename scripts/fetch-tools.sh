#!/bin/bash
# Produces the tools bundled in PageCapture.app/Contents/Helpers (arm64):
#   build/tools/{ffmpeg,ffprobe}  built from the official FFmpeg source tarball, static, LGPL,
#                                 remux plus poster-frame extraction only, no network protocols
#   build/tools/yt-dlp            the official yt-dlp_macos release binary
#   build/tools/deno              the official deno-aarch64-apple-darwin release binary
# and their licence texts in build/notices/. Pins and the download helper are in tool-pins.sh.
# Every download is pinned and checked against its SHA-256. Finished steps are skipped on reruns.
set -euo pipefail
cd "$(dirname "$0")/.."

. scripts/tool-pins.sh

TOOLS=build/tools
NOTICES=build/notices
# The exact FFmpeg build recipe, for the corresponding-source bundle (make-source-bundle.sh).
FFMPEG_BUILD_TXT="$CACHE/ffmpeg-build.txt"
mkdir -p "$CACHE" "$TOOLS" "$NOTICES"

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

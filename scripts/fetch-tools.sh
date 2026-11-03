#!/bin/bash
# Produces the tools bundled in PageCapture.app/Contents/Helpers (arm64):
#   build/tools/{ffmpeg,ffprobe}  built from the official FFmpeg source tarball, static, LGPL,
#                                 remux plus poster-frame extraction only, no network protocols
#   build/tools/yt-dlp            the official yt-dlp_macos release binary
#   build/tools/deno              the official deno-aarch64-apple-darwin release binary
# and their licence texts in build/notices/.
# Every download is pinned and checked against its SHA-256. Finished steps are skipped on reruns.
set -euo pipefail
cd "$(dirname "$0")/.."

FFMPEG_VERSION=9.0.2
FFMPEG_SHA256=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
YTDLP_VERSION=2026.10.26
YTDLP_SHA256=0f922c15ccc0b83eefa1c8bc9104e434318c4bf16e408e1ee93b7745a6efe0aa
YTDLP_LICENSE_SHA256=7e12e5df4bae12cb21581ba157ced20e1986a0508dd10d0e8a4ab9a4cf94e85c
DENO_VERSION=2.9.8
DENO_SHA256=9f0bf660393da2eaff044cdc7444cb08c73f235849b61d224d825a194ce7c98e
DENO_LICENSE_SHA256=f62497fffecc0852960c8d3e6934b9db86d16396e9b604072e923892cae3a588

CACHE=build/tools-cache
TOOLS=build/tools
NOTICES=build/notices
mkdir -p "$CACHE" "$TOOLS" "$NOTICES"

# fetch URL DEST SHA256: downloads unless DEST already has the expected hash.
fetch() {
    local url=$1 dest=$2 sha=$3
    if [[ -f "$dest" ]] && [[ "$(shasum -a 256 "$dest" | cut -d' ' -f1)" == "$sha" ]]; then
        return
    fi
    echo "Downloading $url"
    curl -fsSL --retry 3 -o "$dest.part" "$url"
    local got
    got="$(shasum -a 256 "$dest.part" | cut -d' ' -f1)"
    if [[ "$got" != "$sha" ]]; then
        rm -f "$dest.part"
        echo "SHA-256 mismatch for $url: expected $sha, got $got" >&2
        exit 1
    fi
    mv "$dest.part" "$dest"
}

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

if [[ -x "$TOOLS/ffmpeg" && -x "$TOOLS/ffprobe" && -f "$FFMPEG_STAMP" ]] \
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
    (
        cd "$SRC"
        env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" \
            ./configure "${FFMPEG_CONFIG[@]}" >build.log 2>&1
        env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" \
            make -j"$(sysctl -n hw.ncpu)" ffmpeg ffprobe >>build.log 2>&1
    ) || { tail -30 "$SRC/build.log" >&2; exit 1; }
    cp "$SRC/ffmpeg" "$SRC/ffprobe" "$TOOLS/"
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
YTDLP_RELEASE="https://github.com/yt-dlp/yt-dlp/releases/download/$YTDLP_VERSION"
if [[ -x "$TOOLS/yt-dlp" ]] && [[ "$(shasum -a 256 "$TOOLS/yt-dlp" | cut -d' ' -f1)" == "$YTDLP_SHA256" ]]; then
    echo "yt-dlp $YTDLP_VERSION: up to date"
else
    # The pinned hash must also be the one the release publishes in SHA2-256SUMS.
    curl -fsSL --retry 3 -o "$CACHE/yt-dlp-SHA2-256SUMS" "$YTDLP_RELEASE/SHA2-256SUMS"
    if ! grep -qx "$YTDLP_SHA256  yt-dlp_macos" "$CACHE/yt-dlp-SHA2-256SUMS"; then
        echo "yt-dlp $YTDLP_VERSION SHA2-256SUMS does not list the pinned yt-dlp_macos hash" >&2
        exit 1
    fi
    fetch "$YTDLP_RELEASE/yt-dlp_macos" "$CACHE/yt-dlp_macos-$YTDLP_VERSION" "$YTDLP_SHA256"
    cp "$CACHE/yt-dlp_macos-$YTDLP_VERSION" "$TOOLS/yt-dlp"
    chmod 755 "$TOOLS/yt-dlp"
fi
fetch "https://raw.githubusercontent.com/yt-dlp/yt-dlp/$YTDLP_VERSION/LICENSE" \
    "$NOTICES/yt-dlp-LICENSE.txt" "$YTDLP_LICENSE_SHA256"

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

echo "Tools ready in $TOOLS"

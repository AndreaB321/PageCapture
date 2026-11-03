#!/bin/bash
# Builds build/PageCapture-third-party-sources-<version>.tar, the corresponding source of the
# bundled tools, to attach to each GitHub release next to the DMG (see THIRD_PARTY_NOTICES.md):
#   ffmpeg-<v>.tar.xz             the FFmpeg source release the bundled ffmpeg/ffprobe are built from
#   ffmpeg-build.txt              how they were built (configure line, environment, compiler)
#   yt-dlp-<v>.tar.gz             yt-dlp's release source tarball (checked against its SHA2-256SUMS)
#   yt-dlp-<v>-git-tag.tar.gz     GitHub's archive of the yt-dlp tag, with the PyInstaller build
#                                 scripts and pinned requirements that produce yt-dlp_macos
#   SHA256SUMS, README.txt
# Deno's source is not included: Deno and V8 are under MIT/BSD-style licences, which do not
# require it. Every file is pinned in tool-pins.sh; downloads are cached in build/tools-cache.
set -euo pipefail
cd "$(dirname "$0")/.."

. scripts/tool-pins.sh

APP_VERSION="$(sed -n 's/^APP_VERSION=//p' scripts/build-app.sh)"
[[ -n "$APP_VERSION" ]] || { echo "APP_VERSION not found in scripts/build-app.sh" >&2; exit 1; }

# Builds ffmpeg if needed, which writes ffmpeg-build.txt for exactly that build.
scripts/fetch-tools.sh
mkdir -p "$CACHE"
fetch "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" \
    "$CACHE/ffmpeg-$FFMPEG_VERSION.tar.xz" "$FFMPEG_SHA256"
check_ytdlp_published "$YTDLP_SRC_SHA256" yt-dlp.tar.gz
fetch "$YTDLP_RELEASE/yt-dlp.tar.gz" "$CACHE/yt-dlp-$YTDLP_VERSION.tar.gz" "$YTDLP_SRC_SHA256"
fetch "https://github.com/yt-dlp/yt-dlp/archive/refs/tags/$YTDLP_VERSION.tar.gz" \
    "$CACHE/yt-dlp-$YTDLP_VERSION-git-tag.tar.gz" "$YTDLP_TAG_SRC_SHA256"

NAME="PageCapture-third-party-sources-$APP_VERSION"
STAGE="build/$NAME"
OUT="build/$NAME.tar"
rm -rf "$STAGE" "$OUT"
mkdir -p "$STAGE"
cp "$CACHE/ffmpeg-$FFMPEG_VERSION.tar.xz" "$CACHE/ffmpeg-build.txt" \
    "$CACHE/yt-dlp-$YTDLP_VERSION.tar.gz" "$CACHE/yt-dlp-$YTDLP_VERSION-git-tag.tar.gz" "$STAGE/"

cat >"$STAGE/README.txt" <<EOF
Corresponding source for the third-party programs bundled in PageCapture $APP_VERSION
(PageCapture.app/Contents/Helpers). THIRD_PARTY_NOTICES.md in the app and in the PageCapture
repository lists every component and its licence.

ffmpeg-$FFMPEG_VERSION.tar.xz
    FFmpeg $FFMPEG_VERSION, unmodified, from https://ffmpeg.org/releases/ (LGPL 2.1 or later).
    ffmpeg-build.txt gives the configure line and environment the bundled ffmpeg and ffprobe
    were built with.

yt-dlp-$YTDLP_VERSION.tar.gz
    yt-dlp $YTDLP_VERSION's source tarball (yt-dlp.tar.gz) from
    $YTDLP_RELEASE/
    Its SHA-256 is the one in that release's SHA2-256SUMS.

yt-dlp-$YTDLP_VERSION-git-tag.tar.gz
    https://github.com/yt-dlp/yt-dlp/archive/refs/tags/$YTDLP_VERSION.tar.gz: the repository
    at the release tag, including bundle/ (the PyInstaller build script and the hash-pinned
    requirements, bundle/requirements/macos*.txt) and .github/workflows/build.yml, which
    produce the yt-dlp_macos executable PageCapture bundles unmodified.
    The executable also contains Python $YTDLP_PYTHON_VERSION and the Python packages listed in
    THIRD_PARTY_NOTICES.md; their sources are published by those projects (python.org, PyPI).

Deno $DENO_VERSION is under the MIT licence and embeds V8 (BSD-3-Clause) and ICU (Unicode
licence), which do not require source distribution. Its source is at
https://github.com/denoland/deno/releases/tag/v$DENO_VERSION (deno_src.tar.gz).
EOF

(cd "$STAGE" && shasum -a 256 ffmpeg-* yt-dlp-* >SHA256SUMS)
tar -cf "$OUT" -C build "$NAME"
rm -rf "$STAGE"
echo "Built $OUT"

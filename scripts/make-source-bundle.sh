#!/bin/bash
# Builds build/PageCapture-third-party-sources-<version>.tar, the corresponding source of the
# bundled tools, to attach to each GitHub release next to the DMG (see THIRD_PARTY_NOTICES.md):
#   ffmpeg-<v>.tar.xz             the FFmpeg source release the bundled ffmpeg/ffprobe are built from
#   ffmpeg-build.txt              how they were built (configure line, environment, compiler)
#   yt-dlp-<v>.tar.gz             yt-dlp's release source tarball (checked against its SHA2-256SUMS)
#   yt-dlp-<v>-git-tag.tar.gz     GitHub's archive of the yt-dlp tag, with the PyInstaller build
#                                 scripts and pinned requirements that produce yt-dlp_macos
#   libiconv-<v>.tar.gz           GNU libiconv, which lxml's macOS wheel (in the MarkItDown runtime)
#                                 links statically (LGPL-2.1)
#   libxml2-<v>.tar.xz, libxslt-<v>.tar.xz, zlib-<v>.tar.gz
#                                 the other libraries lxml's wheel links statically
#   lxml-<v>.tar.gz               lxml's sdist, whose buildlibxml.py builds lxml against given
#                                 libiconv, libxml2, libxslt and zlib tarballs
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
fetch "https://ftp.gnu.org/pub/gnu/libiconv/libiconv-$LIBICONV_VERSION.tar.gz" \
    "$CACHE/libiconv-$LIBICONV_VERSION.tar.gz" "$LIBICONV_SHA256"
fetch "https://files.pythonhosted.org/packages/source/l/lxml/lxml-$LXML_VERSION.tar.gz" \
    "$CACHE/lxml-$LXML_VERSION.tar.gz" "$LXML_SRC_SHA256"
fetch "https://download.gnome.org/sources/libxml2/${LIBXML2_VERSION%.*}/libxml2-$LIBXML2_VERSION.tar.xz" \
    "$CACHE/libxml2-$LIBXML2_VERSION.tar.xz" "$LIBXML2_SHA256"
fetch "https://download.gnome.org/sources/libxslt/${LIBXSLT_VERSION%.*}/libxslt-$LIBXSLT_VERSION.tar.xz" \
    "$CACHE/libxslt-$LIBXSLT_VERSION.tar.xz" "$LIBXSLT_SHA256"
fetch "https://zlib.net/fossils/zlib-$ZLIB_VERSION.tar.gz" \
    "$CACHE/zlib-$ZLIB_VERSION.tar.gz" "$ZLIB_SHA256"

NAME="PageCapture-third-party-sources-$APP_VERSION"
STAGE="build/$NAME"
OUT="build/$NAME.tar"
rm -rf "$STAGE" "$OUT"
mkdir -p "$STAGE"
cp "$CACHE/ffmpeg-$FFMPEG_VERSION.tar.xz" "$CACHE/ffmpeg-build.txt" \
    "$CACHE/yt-dlp-$YTDLP_VERSION.tar.gz" "$CACHE/yt-dlp-$YTDLP_VERSION-git-tag.tar.gz" \
    "$CACHE/libiconv-$LIBICONV_VERSION.tar.gz" "$CACHE/lxml-$LXML_VERSION.tar.gz" \
    "$CACHE/libxml2-$LIBXML2_VERSION.tar.xz" "$CACHE/libxslt-$LIBXSLT_VERSION.tar.xz" \
    "$CACHE/zlib-$ZLIB_VERSION.tar.gz" "$STAGE/"

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

libiconv-$LIBICONV_VERSION.tar.gz, libxml2-$LIBXML2_VERSION.tar.xz, libxslt-$LIBXSLT_VERSION.tar.xz, zlib-$ZLIB_VERSION.tar.gz
    The C libraries the lxml wheel in the bundled MarkItDown runtime links statically, unmodified,
    from https://ftp.gnu.org/pub/gnu/libiconv/ (libiconv, LGPL 2.1), https://download.gnome.org/sources/
    (libxml2 and libxslt, MIT) and https://zlib.net/fossils/ (zlib, zlib licence).

lxml-$LXML_VERSION.tar.gz
    lxml $LXML_VERSION's source distribution from PyPI (BSD-3-Clause). Its buildlibxml.py builds
    lxml's static libraries from the four tarballs above. To rebuild lxml with your own copy of one
    of them, unpack the sdist, put your tarballs in a directory next to the others, and run, inside it:
        python3 setup.py build_ext --static-deps --download-dir <that directory> \\
            --libxml2-version $LIBXML2_VERSION --libxslt-version $LIBXSLT_VERSION \\
            --zlib-version $ZLIB_VERSION --libiconv-version $LIBICONV_VERSION
    No network is needed when the directory holds all four. Then replace the lxml package in the
    markitdown runtime and re-sign it: THIRD_PARTY_NOTICES.md has the steps. The runtime's other
    Python packages are the PyPI wheels listed in scripts/markitdown-requirements.txt, unmodified
    except for compiled bytecode and an ad-hoc re-signature; their sources are published on PyPI.

Deno $DENO_VERSION is under the MIT licence and embeds V8 (BSD-3-Clause) and ICU (Unicode
licence), which do not require source distribution. Its source is at
https://github.com/denoland/deno/releases/tag/v$DENO_VERSION (deno_src.tar.gz).
EOF

(cd "$STAGE" && shasum -a 256 ffmpeg-* yt-dlp-* libiconv-* libxml2-* libxslt-* zlib-* lxml-* >SHA256SUMS)
tar -cf "$OUT" -C build "$NAME"
rm -rf "$STAGE"
echo "Built $OUT"

# Sourced by fetch-tools.sh and make-source-bundle.sh: the pinned versions and SHA-256s of the
# bundled tools, the licence texts and the corresponding sources, plus the checked download helper.
# Run from the repository root.

FFMPEG_VERSION=9.0.2
FFMPEG_SHA256=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
YTDLP_VERSION=2026.10.26
YTDLP_SHA256=0f922c15ccc0b83eefa1c8bc9104e434318c4bf16e408e1ee93b7745a6efe0aa
# The Python inside yt-dlp_macos (its PyInstaller archive's Python.framework Info.plist).
YTDLP_PYTHON_VERSION=3.14.7
YTDLP_LICENSE_SHA256=7e12e5df4bae12cb21581ba157ced20e1986a0508dd10d0e8a4ab9a4cf94e85c
YTDLP_THIRD_PARTY_SHA256=472aefe951c7db35e1657c1d13fd337140511ed6f2b329205105ad441c5a02b7
# yt-dlp.tar.gz, the release's source tarball (listed in its SHA2-256SUMS).
YTDLP_SRC_SHA256=21f942d258d25cc4e60b4982a25c423460f0bebb835f38e6dfd1fcb140087f95
# GitHub's archive of the git tag: the release tarball leaves out bundle/ and .github/workflows/,
# the scripts that build yt-dlp_macos. yt-dlp publishes no checksum for it; this is the one we got.
YTDLP_TAG_SRC_SHA256=7d5da51731c3f5f5db13d16249fae085e170cc58807c43d68dcb41b7ede99a0d
GPL3_SHA256=3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986
DENO_VERSION=2.9.8
DENO_SHA256=9f0bf660393da2eaff044cdc7444cb08c73f235849b61d224d825a194ce7c98e
DENO_LICENSE_SHA256=f62497fffecc0852960c8d3e6934b9db86d16396e9b604072e923892cae3a588
# Deno 2.9.8 uses the v8 crate 150.4.0 (denoland/rusty_v8), whose submodules pin these commits.
V8_COMMIT=ac1e23989121713ca642f6650b34deff7b686896
V8_LICENSE_SHA256=6ab33af8774a0f396ee3aeeb761e3229057682d6f9fa7f572e390c2cb3a6e509
ICU_COMMIT=ee5f27adc28bd3f15b2c293f726d14d2e336cbd5
ICU_LICENSE_SHA256=451167c55c0fa447cc2d5632714f5e3c567fe4f1e1badefab2c1333852198aca
# MarkItDown runs on CPython from python-build-standalone (astral-sh); its Python packages are
# pinned, wheel by wheel, in scripts/markitdown-requirements.txt.
MARKITDOWN_VERSION=0.1.9
PBS_RELEASE=20261110
PBS_PYTHON_VERSION=3.13.18
# cpython-<v>+<release>-aarch64-apple-darwin-install_only_stripped.tar.gz, the runtime.
PBS_SHA256=7a2384641584ab9984221fcb0fc9265df465922af71be71410529e2a9c3f0540
# The same build's pgo+lto-full.tar.zst, only for its licenses/ (the components' licence texts).
PBS_FULL_SHA256=11c316dfa24e1184e91de3c1434ed1d3e986c30b2d7a0273257067efe611a677
# Licence texts the wheels leave out, from each project's repository at the release tag
# (python-cobble has no licence file: its README states BSD-2-Clause).
MARKITDOWN_LICENSE_SHA256=c2cfccb812fe482101a8f04597dfc5a9991a6b2748266c47ac91b6a5aae15383
MAGIKA_VERSION=1.0.3
MAGIKA_LICENSE_SHA256=58d1e17ffe5109a7ae296caafcadfdbe6a7d176f0bc4ab01e12a689b0499d8bd
FLATBUFFERS_VERSION=25.12.19
FLATBUFFERS_LICENSE_SHA256=cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30
COBBLE_VERSION=0.1.4
COBBLE_README_SHA256=d6d46202db973b560d2f521dced9110b3e0a46d9a75e1428dade8b7608dd0cca
# lxml's wheel links its C libraries statically: GNU libiconv (LGPL-2.1), libxml2, libxslt and zlib.
# Their sources and lxml's (with the build scripts) go into the sources bundle. fetch-tools.sh
# checks the libiconv and lxml versions against the install. The versions are those lxml 6.1.3
# reports (etree.LIBXML_COMPILED_VERSION, LIBXSLT_COMPILED_VERSION) and its binary's zlib banner.
LXML_VERSION=6.1.3
LXML_SRC_SHA256=45222d94ddd511536f3b2f7d9deae3b2339b4ce0f075f1ca25703b07cad9dd21
LIBICONV_VERSION=1.18
LIBICONV_SHA256=3b08f5f4f9b4eb82f151a7040bfd6fe6c6fb922efe4b1659c66ea933276965e8
# libxml2 and libxslt: the hashes are those in download.gnome.org's libxml2-2.14.6.sha256sum and
# libxslt-1.1.43.sha256sum, and in lxml's own buildlibxml.py.
LIBXML2_VERSION=2.14.6
LIBXML2_SHA256=7ce458a0affeb83f0b55f1f4f9e0e55735dbfc1a9de124ee86fb4a66b597203a
LIBXSLT_VERSION=1.1.43
LIBXSLT_SHA256=5a3d6b383ca5afc235b171118e90f5ff6aa27e9fea3303065231a6d403f0183a
# zlib 1.3.2: zlib.net has moved on to 1.4, so this is from https://zlib.net/fossils/. The same
# hash is the one of the GitHub release asset (madler/zlib v1.3.2) and of lxml's buildlibxml.py.
# zlib publishes no .sha256 or .asc file for it.
ZLIB_VERSION=1.3.2
ZLIB_SHA256=bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16
LGPL21_SHA256=20e50fe7aae3e56378ebf0417d9de904f55a0e61e4df315333e632a4d3555d95

CACHE=build/tools-cache
YTDLP_RELEASE="https://github.com/yt-dlp/yt-dlp/releases/download/$YTDLP_VERSION"
PBS_URL="https://github.com/astral-sh/python-build-standalone/releases/download/$PBS_RELEASE"
PBS_NAME="cpython-$PBS_PYTHON_VERSION+$PBS_RELEASE-aarch64-apple-darwin"

# fetch URL DEST SHA256: downloads unless DEST already has the expected hash.
fetch() {
    local url=$1 dest=$2 sha=$3
    if [[ -f "$dest" ]] && [[ "$(shasum -a 256 "$dest" | cut -d' ' -f1)" == "$sha" ]]; then
        return
    fi
    echo "Downloading $url"
    curl -fsSL --retry 3 -o "$dest.part" "$url"
    check_and_place "$url" "$dest" "$sha"
}

# copy_pinned SRC DEST SHA256: like fetch, for a file kept in the repository (scripts/licenses).
copy_pinned() {
    local src=$1 dest=$2 sha=$3
    cp "$src" "$dest.part"
    check_and_place "$src" "$dest" "$sha"
}

# fetch_base64 URL DEST SHA256: like fetch, for googlesource's ?format=TEXT (base64) file view;
# the hash is that of the decoded file.
fetch_base64() {
    local url=$1 dest=$2 sha=$3
    if [[ -f "$dest" ]] && [[ "$(shasum -a 256 "$dest" | cut -d' ' -f1)" == "$sha" ]]; then
        return
    fi
    echo "Downloading $url"
    curl -fsSL --retry 3 "$url" | base64 -D >"$dest.part"
    check_and_place "$url" "$dest" "$sha"
}

check_and_place() {
    local url=$1 dest=$2 sha=$3 got
    got="$(shasum -a 256 "$dest.part" | cut -d' ' -f1)"
    if [[ "$got" != "$sha" ]]; then
        rm -f "$dest.part"
        echo "SHA-256 mismatch for $url: expected $sha, got $got" >&2
        exit 1
    fi
    mv "$dest.part" "$dest"
}

# The release's SHA2-256SUMS must list SHA256 for NAME: ties a pin to what yt-dlp published.
check_ytdlp_published() {
    local sha=$1 name=$2
    curl -fsSL --retry 3 -o "$CACHE/yt-dlp-SHA2-256SUMS" "$YTDLP_RELEASE/SHA2-256SUMS"
    if ! grep -qx "$sha  $name" "$CACHE/yt-dlp-SHA2-256SUMS"; then
        echo "yt-dlp $YTDLP_VERSION SHA2-256SUMS does not list the pinned $name hash" >&2
        exit 1
    fi
}

# Likewise for python-build-standalone's SHA256SUMS.
check_pbs_published() {
    local sha=$1 name=$2
    curl -fsSL --retry 3 -o "$CACHE/pbs-$PBS_RELEASE-SHA256SUMS" "$PBS_URL/SHA256SUMS"
    if ! grep -qxF "$sha  $name" "$CACHE/pbs-$PBS_RELEASE-SHA256SUMS"; then
        echo "python-build-standalone $PBS_RELEASE SHA256SUMS does not list the pinned $name hash" >&2
        exit 1
    fi
}

# md_tree_digest DIR: one SHA-256 over every file (path relative to DIR, content) and symlink
# (path, target) of DIR, so a changed, added or removed file changes it.
md_tree_digest() {
    (
        cd "$1"
        find . \( -type f -o -type l \) -print0 | LC_ALL=C sort -z | while IFS= read -r -d '' f; do
            if [[ -L "$f" ]]; then
                printf '%s  link:%s\n' "$f" "$(readlink "$f")"
            else
                shasum -a 256 "$f"
            fi
        done | shasum -a 256 | cut -d' ' -f1
    )
}

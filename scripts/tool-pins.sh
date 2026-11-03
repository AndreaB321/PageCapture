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

CACHE=build/tools-cache
YTDLP_RELEASE="https://github.com/yt-dlp/yt-dlp/releases/download/$YTDLP_VERSION"

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

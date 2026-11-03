#!/bin/bash
# Regenerates the tiny video fixtures in Tests/PageCaptureCoreTests/Fixtures/video/ that
# ToolsTests feeds to the bundled ffmpeg. The bundled ffmpeg cannot encode video, so this uses a
# full ffmpeg from PATH (e.g. Homebrew's, with libx264, libx265, libvpx and libopus). Run it only
# when the fixtures need to change; the output is committed.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=Tests/PageCaptureCoreTests/Fixtures/video
rm -rf "$OUT"
mkdir -p "$OUT/hls-ts" "$OUT/hls-aes" "$OUT/hls-fmp4" "$OUT/hls-split/video" "$OUT/hls-split/audio"

ff() { ffmpeg -hide_banner -loglevel error -y "$@"; }
VIDEO=(-f lavfi -i "testsrc2=size=64x48:rate=10:duration=2")
AUDIO=(-f lavfi -i "sine=frequency=440:sample_rate=16000:duration=2")
H264=(-c:v libx264 -preset veryslow -crf 40 -pix_fmt yuv420p -g 10 -bf 0)
AAC=(-c:a aac -b:a 16k -ac 1)
BITEXACT=(-fflags +bitexact -flags:v +bitexact -flags:a +bitexact -map_metadata -1)

# Plain HLS with MPEG-TS segments.
ff "${VIDEO[@]}" "${AUDIO[@]}" "${H264[@]}" "${AAC[@]}" "${BITEXACT[@]}" \
    -f hls -hls_time 1 -hls_list_size 0 -hls_segment_filename "$OUT/hls-ts/seg%d.ts" "$OUT/hls-ts/index.m3u8"

# HLS with clear-key AES-128 segments; the key file is referenced by a relative URI.
printf '0123456789abcdef' >"$OUT/hls-aes/key.bin"
KEYINFO="$(mktemp)"
printf 'key.bin\n%s\n' "$OUT/hls-aes/key.bin" >"$KEYINFO"
ff "${VIDEO[@]}" "${AUDIO[@]}" "${H264[@]}" "${AAC[@]}" "${BITEXACT[@]}" \
    -f hls -hls_time 1 -hls_list_size 0 -hls_key_info_file "$KEYINFO" \
    -hls_segment_filename "$OUT/hls-aes/seg%d.ts" "$OUT/hls-aes/index.m3u8"
rm -f "$KEYINFO"

# HLS with fragmented-MP4 segments.
ff "${VIDEO[@]}" "${AUDIO[@]}" "${H264[@]}" "${AAC[@]}" "${BITEXACT[@]}" \
    -f hls -hls_time 1 -hls_list_size 0 -hls_segment_type fmp4 -hls_fmp4_init_filename init.mp4 \
    -hls_segment_filename "$OUT/hls-fmp4/seg%d.m4s" "$OUT/hls-fmp4/index.m3u8"

# HLS split into a video-only fMP4 playlist and an audio-only MPEG-TS playlist, both AES-128
# encrypted with one key, as a master playlist with a separate audio rendition serves them.
printf 'fedcba9876543210' >"$OUT/hls-split/key.bin"
KEYINFO="$(mktemp)"
printf '../key.bin\n%s\n' "$OUT/hls-split/key.bin" >"$KEYINFO"
# ffmpeg cannot encrypt fMP4 segments, so they are written clear and encrypted whole with openssl
# (HLS AES-128 is AES-128-CBC with PKCS7 padding over the whole segment); the init segment stays clear.
ff "${VIDEO[@]}" "${H264[@]}" "${BITEXACT[@]}" \
    -f hls -hls_time 1 -hls_list_size 0 -hls_segment_type fmp4 -hls_fmp4_init_filename init.mp4 \
    -hls_segment_filename "$OUT/hls-split/video/seg%d.m4s" "$OUT/hls-split/video/index.m3u8"
for n in 0 1; do
    openssl aes-128-cbc -K "$(xxd -p "$OUT/hls-split/key.bin")" -iv "$(printf '%032x' "$n")" \
        -in "$OUT/hls-split/video/seg$n.m4s" -out "$OUT/hls-split/video/seg$n.m4s.enc"
    mv "$OUT/hls-split/video/seg$n.m4s.enc" "$OUT/hls-split/video/seg$n.m4s"
done
# The key tag goes after EXT-X-MAP, so it applies to the media segments only (IV = sequence number).
sed -i '' 's|^#EXT-X-MAP:.*|&\
#EXT-X-KEY:METHOD=AES-128,URI="../key.bin"|' "$OUT/hls-split/video/index.m3u8"
ff "${AUDIO[@]}" "${AAC[@]}" "${BITEXACT[@]}" \
    -f hls -hls_time 1 -hls_list_size 0 -hls_key_info_file "$KEYINFO" \
    -hls_segment_filename "$OUT/hls-split/audio/seg%d.ts" "$OUT/hls-split/audio/index.m3u8"
rm -f "$KEYINFO"

# Separate video-only and audio-only files, as yt-dlp downloads them before merging.
ff "${VIDEO[@]}" "${H264[@]}" "${BITEXACT[@]}" "$OUT/video-only.mp4"
ff "${AUDIO[@]}" "${AAC[@]}" "${BITEXACT[@]}" "$OUT/audio-only.m4a"
ff "${VIDEO[@]}" -c:v libvpx-vp9 -crf 50 -b:v 0 -deadline good -g 10 "${BITEXACT[@]}" "$OUT/video-only.webm"
ff "${AUDIO[@]}" -c:a libopus -b:a 8k -ac 1 "${BITEXACT[@]}" "$OUT/audio-only.webm"

# HEVC for the poster-frame decoder.
ff "${VIDEO[@]}" -c:v libx265 -preset veryslow -crf 40 -pix_fmt yuv420p -tag:v hvc1 \
    -x265-params log-level=error "${BITEXACT[@]}" "$OUT/video-hevc.mp4"

du -sh "$OUT"

#!/usr/bin/env bash
# Exercise *exactly* the ffmpeg pipeline Tango drives (see
# tango-pvp/src/replay/export.rs) so a build that is missing any enabled
# component fails here instead of in users' replay exports.
#
# Usage: smoke-test.sh /path/to/ffmpeg[.exe]
set -euo pipefail

[ $# -ge 1 ] || { echo "usage: $0 /path/to/ffmpeg" >&2; exit 2; }

# Absolutise the binary path before we cd into the scratch dir. Using a
# real (Windows-native under MSYS2) cwd + relative data filenames avoids
# any MSYS path-translation surprises when the native exe opens files.
FF="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"

W=240; H=160                 # GBA screen (doubled to 480 for two-sided)
FR="16777216/280896"         # exact GBA frame rate Tango passes

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"

echo "== $("$FF" -hide_banner -version | head -n1) =="

# 8 RGBA frames of zeros + ~1s of stereo s16le silence (48k*2ch*2B).
dd if=/dev/zero of=frames.rgba bs=$((W * H * 4)) count=8 status=none
dd if=/dev/zero of=audio.s16le bs=192000 count=1 status=none

run() { echo "+ ffmpeg $*"; "$FF" -hide_banner -loglevel error -y "$@"; }

# Per-stream intermediates are matroska (.mkv); the mux step stream-copies
# them into the final container: scaled export -> .mp4 (faststart), lossless
# export -> .mkv (libx264rgb + flac, which mkv holds natively).

# 1) Lossless video path (scale==0): rawvideo rgba -> libx264rgb, via pipe:
cat frames.rgba | run \
  -f rawvideo -pixel_format rgba -video_size ${W}x${H} -framerate "$FR" -i pipe: \
  -c:v libx264rgb -preset ultrafast -qp 0 -f matroska v_lossless.mkv

# 2) Scaled video path: rawvideo rgba -> neighbor scale + yuv420p -> libx264
run -f rawvideo -pixel_format rgba -video_size ${W}x${H} -framerate "$FR" -i frames.rgba \
  -c:v libx264 -vf "scale=iw*2:ih*2:flags=neighbor,format=yuv420p" \
  -force_key_frames "expr:gte(t,n_forced/2)" -crf 18 -bf 2 -f matroska v_scaled.mkv

# 3) AAC audio (scaled export)   4) FLAC audio (lossless export)
run -f s16le -ar 48k -ac 2 -i audio.s16le -c:a aac -ar 48000 -b:a 384k -ac 2 -f matroska a_aac.mkv
run -f s16le -ar 48k -ac 2 -i audio.s16le -c:a flac -f matroska a_flac.mkv

# 5a) Scaled mux (stream copy) -> .mp4 with faststart.
run -i v_scaled.mkv -i a_aac.mkv -c:v copy -c:a copy -map 0 -map 1 \
  -movflags +faststart -strict -2 out_scaled.mp4
# 5b) Lossless mux (stream copy) -> .mkv (no mp4-only flags).
run -i v_lossless.mkv -i a_flac.mkv -c:v copy -c:a copy -map 0 -map 1 out_lossless.mkv

for f in v_lossless.mkv v_scaled.mkv a_aac.mkv a_flac.mkv out_scaled.mp4 out_lossless.mkv; do
  [ -s "$f" ] || { echo "FAIL: $f missing or empty" >&2; exit 1; }
  printf 'ok  %-16s %8s bytes\n' "$f" "$(wc -c < "$f")"
done

echo "SMOKE TEST PASSED"

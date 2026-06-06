#!/usr/bin/env bash
# Print the latest stable FFmpeg release version (e.g. "8.1.1") by asking
# the upstream git mirror for its release tags. Release tags look like
# "nX.Y" / "nX.Y.Z"; pre-release/dev tags (n8.0-dev, *-rc*) carry letters
# and are filtered out. Override FFMPEG_GIT to point at a mirror.
set -euo pipefail

: "${FFMPEG_GIT:=https://github.com/FFmpeg/FFmpeg.git}"

git ls-remote --tags --refs "$FFMPEG_GIT" \
  | sed 's#.*/tags/##' \
  | grep -E '^n[0-9]+(\.[0-9]+)+$' \
  | sed 's/^n//' \
  | sort -V \
  | tail -n1

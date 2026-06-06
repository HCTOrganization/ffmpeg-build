#!/usr/bin/env bash
# Build a static libx264 into $PREFIX. Tango's libx264 / libx264rgb
# encoders are the only external dependency the minimal ffmpeg pulls in.
#
# Env contract:
#   PREFIX        install prefix (required)           e.g. $PWD/prefix
#   X264_SRC      checkout dir   (default $PWD/x264)
#   X264_REF      git ref        (default: stable; see ffmpeg-config-common.sh)
#   X264_HOST     cross host triple, e.g. x86_64-apple-darwin (optional)
#   EXTRA_CFLAGS  / EXTRA_LDFLAGS / EXTRA_ASFLAGS      (optional; arch flags)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ffmpeg-config-common.sh
source "$HERE/ffmpeg-config-common.sh"

: "${PREFIX:?set PREFIX}"
: "${X264_SRC:=${PWD}/x264}"

if [ ! -f "$X264_SRC/configure" ]; then
  git clone --depth 1 --branch "$X264_REF" \
    https://code.videolan.org/videolan/x264.git "$X264_SRC"
fi
cd "$X264_SRC"

# Fresh tree each run so cross/native object files never mix.
make distclean >/dev/null 2>&1 || true

args=(
  --prefix="$PREFIX"
  --enable-static
  --enable-pic
  --disable-cli
  --disable-opencl
  --bit-depth=8          # Tango only ever feeds 8-bit RGBA / YUV420P
)
[ -n "${X264_HOST:-}"     ] && args+=("--host=${X264_HOST}")
[ -n "${EXTRA_CFLAGS:-}"  ] && args+=("--extra-cflags=${EXTRA_CFLAGS}")
[ -n "${EXTRA_LDFLAGS:-}" ] && args+=("--extra-ldflags=${EXTRA_LDFLAGS}")
[ -n "${EXTRA_ASFLAGS:-}" ] && args+=("--extra-asflags=${EXTRA_ASFLAGS}")

echo "+ x264 configure ${args[*]}"
./configure "${args[@]}"

make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"
make install
echo "x264 installed into $PREFIX"

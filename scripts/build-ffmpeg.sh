#!/usr/bin/env bash
# Download + build the minimal static ffmpeg binary, linking the static
# libx264 already installed into $PREFIX by build-x264.sh.
#
# Env contract:
#   PREFIX        prefix where libx264 was installed (required)
#   OUTPUT        path to write the final ffmpeg binary (required)
#   FFMPEG_SRC    source dir (default $PWD/ffmpeg-$FFMPEG_VERSION)
#   EXE_SUFFIX    ".exe" on Windows, empty otherwise
#   EXTRA_CFLAGS  / EXTRA_LDFLAGS   appended to configure (arch / -static)
#   FFMPEG_EXTRA  extra space-separated configure flags (cross-compile etc.)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ffmpeg-config-common.sh
source "$HERE/ffmpeg-config-common.sh"

: "${PREFIX:?set PREFIX}"
: "${OUTPUT:?set OUTPUT}"

# No version pinned -> build whatever the newest upstream release is.
if [ -z "${FFMPEG_VERSION:-}" ]; then
  FFMPEG_VERSION="$("$HERE/latest-ffmpeg-version.sh")"
  echo "Resolved latest FFmpeg release: $FFMPEG_VERSION"
fi
export FFMPEG_VERSION

: "${FFMPEG_SRC:=${PWD}/ffmpeg-${FFMPEG_VERSION}}"

if [ ! -f "$FFMPEG_SRC/configure" ]; then
  curl -fL -o "ffmpeg-${FFMPEG_VERSION}.tar.xz" \
    "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz"
  rm -rf "$FFMPEG_SRC"
  mkdir -p "$FFMPEG_SRC"
  tar xf "ffmpeg-${FFMPEG_VERSION}.tar.xz" -C "$FFMPEG_SRC" --strip-components=1
fi
cd "$FFMPEG_SRC"

# Always start from a clean configure so re-runs / arch switches are sane.
make distclean >/dev/null 2>&1 || true

export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

# How to point the compiler/linker at the libx264 in $PREFIX. Defaults
# are GCC/Clang-style; the MSVC job overrides PREFIX_LDFLAGS (link.exe
# wants -libpath:, and x264 is found via pkg-config anyway). Note the
# `=` (not `:=`) so an explicitly-empty value is honoured.
: "${PREFIX_CFLAGS=-I$PREFIX/include}"
: "${PREFIX_LDFLAGS=-L$PREFIX/lib}"

args=(
  --pkg-config-flags=--static
  --extra-cflags="$PREFIX_CFLAGS ${EXTRA_CFLAGS:-}"
  --extra-ldflags="$PREFIX_LDFLAGS ${EXTRA_LDFLAGS:-}"
)
if [ -n "${FFMPEG_EXTRA:-}" ]; then
  read -ra _extra <<< "$FFMPEG_EXTRA"
  args+=("${_extra[@]}")
fi

# MSVC-only: give the Coded Bitstream layer a non-empty codec-type table.
# Enabling the mov/mp4 muxer unconditionally compiles libavformat's cbs.o
# (libavformat/cbs.c is just `#include "libavcodec/cbs.c"`, for the av1C box).
# In our --disable-everything build no CBS type is enabled, so cbs.c:33's
# cbs_type_table[] collapses to a *zero-length* array with an empty `{}`
# initializer. GCC/Clang accept that (GNU zero-length-array extension); MSVC
# does not -- newer cl.exe (vs2026) hard-errors C7757 ("an array of unknown
# size cannot be initialized by an empty initializer"), older VS2022 dies with
# a C1001 ICE. Enabling the av1 parser selects cbs_av1 (CONFIG_CBS_AV1=1), so
# &ff_cbs_type_av1 lands in the table and it's no longer empty. The AV1 CBS
# code is never executed (we never mux AV1), so this is purely a compile fix;
# gated to MSVC so the other platforms keep the leanest possible binary.
case "${FFMPEG_EXTRA:-}" in
  *--toolchain=msvc*) args+=(--enable-parser=av1) ;;
esac

# shellcheck disable=SC2046  # intentional word-split of the flag lists
echo "+ ffmpeg configure ${args[*]} <component+shape flags>"
./configure \
  "${args[@]}" \
  $(ffmpeg_shape_flags) \
  $(ffmpeg_component_flags)

make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"

mkdir -p "$(dirname "$OUTPUT")"
cp "ffmpeg${EXE_SUFFIX:-}" "$OUTPUT"
# Best-effort strip (already stripped by the build on most platforms).
strip "$OUTPUT" >/dev/null 2>&1 || true

echo "=== built $OUTPUT ==="
"$OUTPUT" -hide_banner -version | head -n1 || true

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

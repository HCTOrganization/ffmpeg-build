# ffmpeg-build

Reproducible builds of a **minimal static `ffmpeg`** for [Tango](https://github.com/tangobattle).

Tango doesn't link `libav*` — it ships a standalone `ffmpeg` binary next to
the app and shells out to it to encode replay exports
(`tango-pvp/src/replay/export.rs`). This repo builds that binary for every
platform Tango ships on, containing **only** the codecs/muxers/filters the
exporter actually drives and nothing else (we start from
`--disable-everything` and re-enable feature by feature).

It replaces the previously-bundled `eugeneware/ffmpeg-static` b6.0 builds,
which carry the full kitchen-sink ffmpeg (~70 MB) when Tango uses a sliver
of it.

## Outputs

The [`build-ffmpeg`](.github/workflows/build.yaml) workflow produces:

| Artifact / release asset      | Platform       | Notes                                       |
| ----------------------------- | -------------- | ------------------------------------------- |
| `ffmpeg-linux-x86_64`         | Linux x86_64   | built on ubuntu-22.04 (glibc baseline)      |
| `ffmpeg-windows-x86_64.exe`   | Windows x86_64 | MSVC toolchain, static CRT — needs no DLLs  |
| `ffmpeg-macos-arm64`          | macOS arm64    | native, min macOS 11.0                      |
| `ffmpeg-macos-x86_64`         | macOS x86_64   | cross-compiled on the arm64 runner          |

The two macOS slices are shipped separately (not `lipo`'d here) because
Tango's `macos/build.sh` already fat-binary's them itself.

The workflow is **manual-only** — start it from the Actions tab (*Run
workflow*). It builds the **latest** FFmpeg release by default; set the
`ffmpeg_version` input (e.g. `7.1.1`) to pin a specific release.

Each run publishes its binaries (each with a `.sha256`) to a GitHub Release
tagged `ffmpeg-<version>`. The workflow creates that tag/release itself — no
tag push is involved — giving stable download URLs, e.g.:

    https://github.com/<owner>/ffmpeg-build/releases/download/ffmpeg-8.1.1/ffmpeg-linux-x86_64

They're also attached to the run as plain Artifacts for quick debugging.

## What's enabled, and why

Single source of truth: [`scripts/ffmpeg-config-common.sh`](scripts/ffmpeg-config-common.sh).
Every line is traced to a Tango code path:

| Component                          | Tango usage                                                  |
| ---------------------------------- | ----------------------------------------------------------- |
| encoder `libx264`                  | scaled export — `-c:v libx264 -vf scale=…,format=yuv420p`   |
| encoder `libx264rgb`               | lossless export (scale = 0) — `-c:v libx264rgb -qp 0`       |
| encoder `aac`                      | scaled-export audio — `-c:a aac -b:a 384k`                  |
| encoder `flac`                     | lossless-export audio — `-c:a flac`                          |
| decoders `rawvideo`, `pcm_s16le`   | the raw RGBA / s16le streams piped from the emulator        |
| demuxers `rawvideo`, `pcm_s16le`   | `-f rawvideo` / `-f s16le` inputs                            |
| demuxer `matroska`                 | mux step reads back the intermediate `.mkv`s                |
| muxer `matroska`                   | intermediates (`-f matroska`) + the final `.mkv` (lossless) |
| muxers `mov`/`mp4`                  | the final `.mp4` (scaled export)                            |
| parsers `h264`, `aac`, `flac`      | stream-copy mux (`-c:v copy -c:a copy`)                     |
| bsf `extract_extradata`            | write `avcC` when copying H.264 into MP4                    |
| bsf `aac_adtstoasc`                | AAC stream-copy safety                                      |
| filters `scale`, `format`          | nearest-neighbour upscale + pixel-format conversion         |
| filters `aresample`/`aformat`/…    | auto-inserted s16 → fltp etc. negotiation                   |
| protocols `file`, `pipe`           | temp files + `-i pipe:`                                     |
| external `libx264` (GPL)           | the H.264 encoders above (`--enable-gpl`)                   |

The side-by-side ("twosided") export is composited in Rust and piped as one
double-width rawvideo stream, so **no** `hstack`/`overlay` filter is needed.

Tango writes its per-stream intermediate temp files as **matroska**
(`-f matroska`, see `tango-pvp/src/replay/export.rs`) and stream-copies them
into the final container. **Scaled** exports produce an `.mp4` (with
`-movflags +faststart`); **lossless** exports (libx264rgb + FLAC, which mp4
only carries via experimental flags) produce an `.mkv` instead — the save
dialog picks the extension to match.

The resulting binaries are GPL (because of x264).

Each build is **smoke-tested** ([`scripts/smoke-test.sh`](scripts/smoke-test.sh))
by running Tango's exact command sequence — both encode paths, both audio
codecs, and the `flac`-in-MP4 / `h264`-in-MP4 stream-copy mux — so a build
missing any enabled component fails in CI rather than in a user's export.

## Versions

Each run builds the **latest** FFmpeg release by default, resolved from the
upstream git tags by `scripts/latest-ffmpeg-version.sh`. To build a specific
release, set the `ffmpeg_version` workflow input. x264 tracks its `stable`
branch (`X264_REF`); pin it to a commit SHA for fully reproducible builds.

## Building locally

```sh
# Linux/macOS (needs nasm, pkg-config, a C compiler, curl, git).
# FFMPEG_VERSION unset -> builds the latest release; set it to pin.
export PREFIX="$PWD/prefix" OUTPUT="$PWD/out/ffmpeg"
./scripts/build-x264.sh
./scripts/build-ffmpeg.sh
./scripts/smoke-test.sh ./out/ffmpeg
```

## Wiring Tango to these builds

Tango's packaging scripts currently download from `eugeneware/ffmpeg-static`.
Point them at this repo's release assets instead — same URL shape, e.g. swap
`.../eugeneware/ffmpeg-static/releases/download/b6.0/ffmpeg-linux-x64` for
`.../<owner>/ffmpeg-build/releases/download/ffmpeg-<version>/ffmpeg-linux-x86_64`:

- `linux/build.sh` — replace the `ffmpeg-linux-x64` download with
  `ffmpeg-linux-x86_64`.
- `win/build.sh` — replace `ffmpeg-win32-x64` with `ffmpeg-windows-x86_64.exe`.
- `macos/build.sh` — replace the two slices with `ffmpeg-macos-arm64` and
  `ffmpeg-macos-x86_64`; its existing `lipo` step fat-binary's them as-is.

(Those edits live in the Tango repo, not here.)

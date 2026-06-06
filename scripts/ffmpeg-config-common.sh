# shellcheck shell=bash
# Single source of truth for the *minimal* FFmpeg that Tango needs.
#
# Tango never links libav*; it ships a standalone `ffmpeg` binary next
# to the app and shells out to it (tango-pvp/src/replay/export.rs). This
# file pins the upstream versions and the exact set of components that
# binary must contain -- and nothing else: we start from
# `--disable-everything` and re-enable one feature at a time, each traced
# back to the Tango code path that needs it.

# Upstream versions.
#   FFMPEG_VERSION: the ffmpeg release to build. Intentionally left unset
#   here -- the CI workflow resolves the newest release and passes it in,
#   and build-ffmpeg.sh falls back to scripts/latest-ffmpeg-version.sh when
#   it is empty, so "no value" means "build the latest release".
#   X264_REF: x264 ships no real release tags; `stable` is the recommended
#   branch. Override with a commit SHA to pin for reproducibility.
: "${X264_REF:=stable}"
export X264_REF

# ---------------------------------------------------------------------------
# Why each component is enabled (grep the flag in export.rs / app.rs):
#
#   Encoders
#     libx264      scaled export    "-c:v libx264 ..."        (default_with_scale, factor set)
#     libx264rgb   lossless export  "-c:v libx264rgb -qp 0"   (scale == 0 path)
#     aac          scaled  audio    "-c:a aac -b:a 384k"
#     flac         lossless audio   "-c:a flac"
#   Decoders (decode the raw streams the emulator pipes in)
#     rawvideo     "-f rawvideo -pixel_format rgba -i pipe:"
#     pcm_s16le    "-f s16le -ar 48k -ac 2 -i pipe:"
#   Demuxers
#     rawvideo     video input            (-f rawvideo)
#     pcm_s16le    audio input            (-f s16le  ->  "s16le" demuxer)
#     matroska     mux step reads back the intermediate .mkv files
#   Muxers
#     matroska     intermediate .mkv files (-f matroska) AND the final
#                  container for lossless exports (.mkv: libx264rgb + flac)
#     mov,mp4      final container for scaled exports (.mp4 "-movflags +faststart")
#   Parsers + BSFs (the mux step stream-copies mkv -> mp4: "-c:v copy -c:a copy")
#     h264,aac,flac parsers
#     extract_extradata   writes the avcC box for H.264-in-MP4
#     aac_adtstoasc       AAC stream-copy safety
#   Filters
#     scale        "-vf scale=...:flags=neighbor"  + auto rgba->gbrp for libx264rgb
#     format       "format=yuv420p"
#     aresample/aformat/null/anull   auto-inserted pixel/sample-format negotiation
#   Protocols
#     file         temp files + final output
#     pipe         "-i pipe:"
#
# The side-by-side ("twosided") export is composited in Rust and piped as
# one double-width rawvideo stream, so no hstack/overlay filter is needed.
# The ffmpeg CLI's filtergraph plumbing (buffer/buffersink/abuffer/
# abuffersink/fps/...) is auto-selected by `--enable-ffmpeg`.
# ---------------------------------------------------------------------------

ffmpeg_component_flags() {
  cat <<'FLAGS'
--disable-everything
--enable-gpl
--enable-libx264
--enable-encoder=libx264,libx264rgb,aac,flac
--enable-decoder=rawvideo,pcm_s16le
--enable-demuxer=rawvideo,pcm_s16le,matroska
--enable-muxer=matroska,mov,mp4
--enable-parser=h264,aac,flac,av1
--enable-bsf=extract_extradata,aac_adtstoasc
--enable-filter=scale,format,null,aresample,aformat,anull,setparams
--enable-protocol=file,pipe
FLAGS
}

# Build-shape flags shared by every platform: a single static `ffmpeg`
# executable, no ffplay/ffprobe, no docs/network/devices, size-optimised.
ffmpeg_shape_flags() {
  cat <<'FLAGS'
--enable-static
--disable-shared
--enable-small
--disable-autodetect
--disable-debug
--disable-doc
--disable-network
--disable-avdevice
--disable-devices
--disable-ffplay
--disable-ffprobe
--enable-ffmpeg
FLAGS
}

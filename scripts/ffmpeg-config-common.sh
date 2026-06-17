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
#     bmp          border probe     "-f image2pipe -vcodec bmp" (tango/src/session.rs)
#     rawvideo     border stream    "-f rawvideo -pix_fmt rgba" (tango/src/session.rs)
#   Decoders (decode the raw streams the emulator pipes in)
#     rawvideo     "-f rawvideo -pixel_format rgba -i pipe:"
#     pcm_s16le    "-f s16le -ar 48k -ac 2 -i pipe:"
#     h264         custom emulator-border MP4 decode (tango/src/session.rs)
#   Demuxers
#     rawvideo     video input            (-f rawvideo)
#     pcm_s16le    audio input            (-f s16le  ->  "s16le" demuxer)
#     matroska     mux step reads back the intermediate .mkv files
#     mov          custom emulator-border MP4 input (tango/src/session.rs)
#   Muxers
#     matroska     intermediate .mkv files (-f matroska) AND the final
#                  container for lossless exports (.mkv: libx264rgb + flac)
#     mov,mp4      final container for scaled exports (.mp4 "-movflags +faststart")
#     image2pipe   custom emulator-border dimension probe (tango/src/session.rs)
#     rawvideo     custom emulator-border raw RGBA stream (tango/src/session.rs)
#   Parsers + BSFs (the mux step stream-copies mkv -> mp4: "-c:v copy -c:a copy")
#     h264,aac,flac parsers
#     extract_extradata   writes the avcC box for H.264-in-MP4
#     aac_adtstoasc       AAC stream-copy safety
#   Filters
#     scale        "-vf scale=...:flags=neighbor"  + auto rgba->gbrp for libx264rgb
#                  + auto yuv->rgba for the border raw-RGBA stream
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
#
# Custom emulator-border video (tango/src/session.rs) shells out to this
# same binary to play a user-chosen MP4 behind the emulator, muted and
# looped:
#   probe : ffmpeg -i in.mp4 -an -frames:v 1 -f image2pipe -vcodec bmp pipe:1
#   stream: ffmpeg -stream_loop -1 -re -i in.mp4 -an -f rawvideo -pix_fmt rgba pipe:1
# That path adds the `mov` demuxer + `h264` decoder (read/decode the MP4),
# the `image2pipe` muxer + `bmp` encoder (the one-frame dimension probe),
# the `rawvideo` muxer + `rawvideo` encoder (the looped raw RGBA stream --
# note the exporter only uses rawvideo as *input*, so only its demuxer/decoder
# were enabled before; writing it needs the muxer AND the encoder),
# and reuses the already-present scale/format filters.
# If border clips might be H.265 / AV1, also enable the `hevc` / `av1`
# decoders (+ `hevc` parser); H.264 is the common MP4 case.
# ---------------------------------------------------------------------------

ffmpeg_component_flags() {
  cat <<'FLAGS'
--disable-everything
--enable-gpl
--enable-libx264
--enable-encoder=libx264,libx264rgb,aac,flac,bmp,rawvideo
--enable-decoder=rawvideo,pcm_s16le,h264
--enable-demuxer=rawvideo,pcm_s16le,matroska,mov
--enable-muxer=matroska,mov,mp4,image2pipe,rawvideo
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

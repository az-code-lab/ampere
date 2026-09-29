#!/bin/bash
# Builds the narrated product introduction into Video/out:
# Ampere-Intro.mp4 (1080p) and Ampere-Intro-4K.mp4 (3840x2160).
#
#   Video/make-video.sh            full render
#   Video/make-video.sh --stills   three PNG frames per scene, for layout checks
#
# Video/out holds only what a run makes or fetches (the videos and the
# music cache) and can be ignored by git; everything a build needs is
# beside this script and in Tests/AmpereTests/VideoSnapshotTests.swift.
#
# Environment:
#   AMPERE_VIDEO_4K      "0" skips the 4K rendering, which takes the longest
#   AMPERE_VIDEO_VOICE   narration voice. Default "system": the voice chosen
#                        in System Settings > Accessibility > Read & Speak
#                        (Spoken Content before macOS 27), which is the only
#                        way to use a Siri voice. Or a name from `say -v ?`,
#                        such as "Ava (Premium)" once downloaded there.
#   AMPERE_VIDEO_RATE    speaking rate in words per minute (default: the voice's own)
#   AMPERE_VIDEO_MUSIC   "Getting it Done" for the other dbclient track, a
#                        file of your own (mp3, m4a, wav, aiff), or "none"
#                        for the narration alone. Unset: Kevin MacLeod's
#                        "Digital Lemonade", the dbclient promo's track,
#                        fetched once into Video/out/music (SHA-256 checked)
#                        and credited on the closing card as CC BY 4.0 asks;
#                        see Video/MUSIC-LICENSE.txt. The bed is held at one
#                        constant level throughout.
#   AMPERE_VIDEO_WORK    scratch directory (default: a fresh /tmp/ampere-video.* dir)
# A finished build is published into Video/site/ here — ampere-intro.mp4,
# ampere-intro.jpg (the poster) and ampere-intro.en.vtt (the captions) —
# which the site's page (the azcode repo's sites/ampere/index.html) names
# at https://goweb.az.ht/files/ampere/video/: a script of the owner's
# uploads Video/site/ there, so the server's binary (which embeds the
# whole site) carries none of it.
#
# Steps: export the real panel in the states the video shows (a snapshot
# test with a fake battery source; nothing touches the SMC or the helper,
# though the hidden capture panel holds keyboard focus for a few seconds),
# then compile and run the composer, which narrates the script with `say`
# and encodes H.264 + AAC with AVFoundation. No third-party tools.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -n "${AMPERE_VIDEO_WORK:-}" ]; then
    WORK=$AMPERE_VIDEO_WORK
else
    WORK=$(mktemp -d /tmp/ampere-video.XXXXXX)
    trap 'rm -rf "$WORK"' EXIT
fi
OUT_DIR="Video/out"
OUT="$OUT_DIR/Ampere-Intro.mp4"
OUT4K="$OUT_DIR/Ampere-Intro-4K.mp4"
mkdir -p "$OUT_DIR"
ARGS=(--panels "$WORK/panels" --work "$WORK" --out "$OUT" --voice "${AMPERE_VIDEO_VOICE:-system}")
[ "${AMPERE_VIDEO_4K:-1}" != "0" ] && ARGS+=(--out-4k "$OUT4K")
[ -n "${AMPERE_VIDEO_RATE:-}" ] && ARGS+=(--rate "$AMPERE_VIDEO_RATE")
if [ -n "${AMPERE_VIDEO_MUSIC:-}" ]; then
    ARGS+=(--music "$AMPERE_VIDEO_MUSIC")
else
    ARGS+=(--music-dir "$OUT_DIR/music")
fi
ARGS+=("$@")

# Same SDK stamping as run.sh / release.sh (see the comment in run.sh).
SDK_FLAGS=(-Xswiftc -Xclang-linker -Xswiftc -isysroot -Xswiftc -Xclang-linker -Xswiftc "$(xcrun --show-sdk-path)")

echo "Exporting panel renders to $WORK/panels"
AMPERE_VIDEO_DIR="$WORK/panels" swift test "${SDK_FLAGS[@]}" --filter VideoSnapshotTests 2>&1 | grep -E "error|Executed|passed|failed" || true
ls "$WORK/panels"/*.png >/dev/null

echo "Compiling the composer"
swiftc -O -parse-as-library Video/IntroVideo.swift -o "$WORK/IntroVideo"

"$WORK/IntroVideo" "${ARGS[@]}"

case " $* " in
    *" --stills "*) ;;
    *)
        HOSTED="Video/site"
        mkdir -p "$HOSTED"
        cp "$OUT" "$HOSTED/ampere-intro.mp4"
        cp "${OUT%.mp4}.jpg" "$HOSTED/ampere-intro.jpg"
        cp "${OUT%.mp4}.en.vtt" "$HOSTED/ampere-intro.en.vtt"
        echo "Published to $HOSTED: ampere-intro.mp4, ampere-intro.jpg, ampere-intro.en.vtt — upload the folder to https://goweb.az.ht/files/ampere/video/"
        ;;
esac

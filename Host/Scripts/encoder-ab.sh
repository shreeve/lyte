#!/usr/bin/env bash
# encoder-ab.sh (HS-24) — the encoder A/B ladder, the supremacy plan's R4.
#
# Runs ON the Linux host (needs hevc_nvenc hardware + ffmpeg). Generates
# two deterministic corpora once, then races recipe variants through
# lyte-encode-check under MATCHED content and rate and prints the table
# the blessed adoption bar reads: luma PSNR at matched bitrate, encode
# wall time (the input→photon contribution), QP posture. One flag per
# variant — no compound moves.
#
#   corpora:  motion  = testsrc2 (the probe's established motion content)
#             desk    = slow gradients + scrolling monospace text (the
#                       AQ-sensitive desktop shape: text edges, gradients)
#   rates:    CBR 8 and 20 Mbps (starved + probe-matched) per corpus.
#   extras:   capped-CQ motion leg and a static ratchet-convergence leg
#             for base + $CANDIDATES (the session posture check).
#
# PSNR method (the probe's, mechanized): decode the Annex-B output and
# compare against the raw BGRx reference with both sides in yuv420p.
# swscale's default RGB→YUV matrix is BT.601/470BG limited — the same
# family NVENC's internal conversion signs (encode.c Stage A comment) —
# and any residual conversion bias is constant across variants, so the
# DELTAS the bar reads are clean.
#
# env overrides: BIN, WORK, SECS, RATES, CANDIDATES.

set -euo pipefail

BIN="${BIN:-$(cd "$(dirname "$0")/.." && pwd)/.build/debug/lyte-encode-check}"
WORK="${WORK:-$HOME/encab}"
W=1600 H=1000 FPS=60
SECS="${SECS:-6}"
RATES="${RATES:-8 20}"
CANDIDATES="${CANDIDATES:-p4}"
FRAMES=$((FPS * SECS))

[ -x "$BIN" ] || { echo "no lyte-encode-check at $BIN (swift build first)"; exit 1; }
command -v ffmpeg >/dev/null || { echo "ffmpeg required"; exit 1; }
mkdir -p "$WORK"

# ---- the ladder: name → lyte-encode-check recipe flags -----------------
# base is Sunshine's exact posture (p1/ull/qres); every other row moves
# ONE knob against its reference point.
variant_flags() {
  case "$1" in
    base)     echo "" ;;
    p2)       echo "--preset p2" ;;
    p3)       echo "--preset p3" ;;
    p4)       echo "--preset p4" ;;
    p5)       echo "--preset p5" ;;
    p6)       echo "--preset p6" ;;
    p7)       echo "--preset p7" ;;
    p1-saq)   echo "--spatial-aq" ;;
    p4-saq)   echo "--preset p4 --spatial-aq" ;;
    p1-taq)   echo "--temporal-aq" ;;
    p1-ll)    echo "--tune ll" ;;
    p4-ll)    echo "--preset p4 --tune ll" ;;
    p4-mp0)   echo "--preset p4 --multipass disabled" ;;
    p4-mpf)   echo "--preset p4 --multipass fullres" ;;
    *)        echo "unknown variant $1" >&2; return 1 ;;
  esac
}
VARIANTS="${VARIANTS:-base p2 p3 p4 p5 p6 p7 p1-saq p4-saq p1-taq p1-ll p4-ll p4-mp0 p4-mpf}"

# ---- corpora (cached) ---------------------------------------------------
MOTION="$WORK/motion-${W}x${H}-${SECS}s.raw"
DESK="$WORK/desk-${W}x${H}-${SECS}s.raw"

if [ ! -f "$MOTION" ]; then
  echo "== generating motion corpus (testsrc2, ${SECS}s)"
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=${W}x${H}:rate=${FPS}" \
    -t "$SECS" -pix_fmt bgr0 -f rawvideo "$MOTION"
fi

if [ ! -f "$DESK" ]; then
  echo "== generating desk corpus (gradients + scrolling text, ${SECS}s)"
  TXT="$WORK/desk-text.txt"
  : > "$TXT"
  for i in $(seq 1 60); do
    printf 'let frame%02d = try packetizer.seal(shard: %d) // 0x%02x — the quick brown fox\n' \
      "$i" "$i" "$i" >> "$TXT"
  done
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "gradients=size=${W}x${H}:rate=${FPS}:speed=0.02" \
    -vf "drawtext=textfile=${TXT}:font='DejaVu Sans Mono':fontsize=24:fontcolor=white:borderw=1:bordercolor=black:x=48:y=h-mod(t*150\,h+1600):line_spacing=8" \
    -t "$SECS" -pix_fmt bgr0 -f rawvideo "$DESK"
fi

# ---- measurement --------------------------------------------------------
psnr_y() { # $1 = raw reference, $2 = hevc bitstream → luma PSNR
  ffmpeg -hide_banner -nostats \
    -f rawvideo -pixel_format bgr0 -video_size "${W}x${H}" \
    -framerate "$FPS" -i "$1" \
    -framerate "$FPS" -i "$2" \
    -lavfi "[0:v]format=yuv420p[ref];[1:v][ref]psnr" -f null - 2>&1 |
    sed -n 's/.*PSNR y:\([0-9.inf]*\) .*/\1/p' | tail -1
}

RESULTS="$WORK/results.tsv"
: > "$RESULTS"

run_leg() { # variant corpus_name corpus_file rate extra_flags…
  local name="$1" corpus="$2" file="$3" rate="$4"; shift 4
  local flags; flags="$(variant_flags "$name")"
  local out="$WORK/out-${name}-${corpus}-${rate}.hevc"
  local line
  line=$("$BIN" --raw "$file" --width $W --height $H --fps $FPS \
      --frames "$FRAMES" --bitrate-mbps "$rate" --out "$out" \
      $flags "$@" 2>/dev/null | grep '^RESULT' || true)
  if [ -z "$line" ] || [[ "$line" == *open-rejected* ]]; then
    printf '%s\t%s\t%s\tOPEN-REJECTED\t-\t-\t-\t%s\n' \
      "$name" "$corpus" "$rate" "$line" >> "$RESULTS"
    echo "  $name/$corpus@$rate: OPEN-REJECTED ($line)"
    return 0
  fi
  local psnr kbps encmean encp99
  psnr=$(psnr_y "$file" "$out")
  kbps=$(sed 's/.* kbps=\([0-9]*\) .*/\1/' <<<"$line")
  encmean=$(sed 's/.* enc_us_mean=\([0-9]*\) .*/\1/' <<<"$line")
  encp99=$(sed 's/.* enc_us_p99=\([0-9]*\) .*/\1/' <<<"$line")
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$name" "$corpus" "$rate" "$psnr" "$kbps" "$encmean" "$encp99" "$line" \
    >> "$RESULTS"
  echo "  $name/$corpus@$rate: PSNR-Y $psnr dB, $kbps kbps, enc mean ${encmean}µs p99 ${encp99}µs"
  rm -f "$out"
}

echo "== CBR ladder (matched rate, ${FRAMES} frames per leg)"
for v in $VARIANTS; do
  for rate in $RATES; do
    run_leg "$v" motion "$MOTION" "$rate"
    run_leg "$v" desk "$DESK" "$rate"
  done
done

echo "== capped-CQ session-posture legs (cq 12, cap 50) for: base $CANDIDATES"
for v in base $CANDIDATES; do
  run_leg "$v" motion "$MOTION" 50 --cq 12
done

echo "== static ratchet-convergence legs (first desk frame × 300, cq 12)"
for v in base $CANDIDATES; do
  flags="$(variant_flags "$v")"
  "$BIN" --raw "$DESK" --width $W --height $H --fps $FPS --static 300 \
    --bitrate-mbps 50 --cq 12 --out "$WORK/static-$v.hevc" $flags |
    sed "s/^/  [$v] /"
  rm -f "$WORK/static-$v.hevc"
done

# ---- the table ----------------------------------------------------------
echo
echo "== ladder table (delta vs base at the same corpus+rate)"
awk -F'\t' '
  $1 == "base" { base[$2 "@" $3] = $4 }
  { rows[NR] = $0 }
  END {
    printf "%-8s %-7s %5s %9s %8s %9s %9s\n",
      "variant", "corpus", "rate", "PSNR-Y", "ΔdB", "enc-mean", "enc-p99"
    for (i = 1; i <= NR; i++) {
      split(rows[i], f, "\t")
      key = f[2] "@" f[3]
      delta = (f[4] == "OPEN-REJECTED" || !(key in base)) ? "-" \
              : sprintf("%+.3f", f[4] - base[key])
      printf "%-8s %-7s %5s %9s %8s %8.2fms %8.2fms\n",
        f[1], f[2], f[3], f[4], delta, f[6] / 1000, f[7] / 1000
    }
  }' "$RESULTS"
echo
echo "results at $RESULTS — adoption bar: PSNR-at-bitrate gain with"
echo "encode time (input→photon) and 60 fps capacity held."

#!/usr/bin/env bash
# rext-probe.sh (H4 V-1) — the NVENC Rext 4:4:4 probe, offline on the
# reference host. Answers the H4 plan's §1 host-side [probe] marks with
# numbers (docs/20260728-194226-lyte-h4-plan.md, slice V-1):
#
#   1. does `-profile rext` + 4:4:4 open on this box's libavcodec/driver
#      (NV_ENC_CAPS_SUPPORT_YUV444_ENCODE via the wrapper's open check),
#      and is `rgb_mode` on the option surface?
#   2. the color-path race — gbrp (identity/full) vs bgr0+rgb_mode
#      (forced 601-limited) vs pre-converted yuv444p (BT.709 full, the
#      conversion-leaf stand-in) — on MATCHED content including the
#      HS-24 text corpus, with MEASURED color truth (Stage A's method:
#      decode, re-interpret under every candidate matrix/range, RGB-PSNR
#      against the raw reference — the winner is what the conversion
#      actually did, the VUI tag is only an assertion to check).
#   3. encode fps capacity + per-frame µs at 2048×1280@60 p4 4:4:4.
#   4. the IDR/frame size distribution vs the FEC protectable ceiling
#      (223,380 B, HS-25) at the 50 Mbps capped-CQ recipe on text.
#   5. the BGRx→gbrp repack cost (measured inside the C leaf).
#
# Offline encode legs only: no capture, no wire, no session — safe to
# run next to a live host. Bitstreams for V-2 (the Mac VideoToolbox
# probe) land under $WORK/keep/. Corpora are big (~16 GB); remove $WORK
# after harvesting keep/ + results.tsv.
#
# env overrides: BIN, WORK, SECS, W, H, FPS.

set -euo pipefail

BIN="${BIN:-$(cd "$(dirname "$0")/.." && pwd)/.build/debug/lyte-encode-check}"
WORK="${WORK:-$HOME/rext-probe}"
W="${W:-2048}" H="${H:-1280}" FPS="${FPS:-60}"
SECS="${SECS:-6}"
FRAMES=$((FPS * SECS))
CEILING=223380 # HS-25: the largest FEC-protectable frame in bytes
KEEP="$WORK/keep"
RESULTS="$WORK/results.tsv"

[ -x "$BIN" ] || { echo "no lyte-encode-check at $BIN (swift build first)"; exit 1; }
command -v ffmpeg >/dev/null || { echo "ffmpeg required"; exit 1; }
mkdir -p "$WORK" "$KEEP"
: > "$RESULTS"

# ---- the paths under race ------------------------------------------------
# p420   = today's shipped path (bgr0 in, NVENC internal → 4:2:0) — baseline
# gbrp   = planar RGB in → Rext identity-matrix full-range (zero conversion)
# rgbmode= bgr0 in + rgb_mode=yuv444 → driver converts, forced 601-limited
# conv   = pre-converted BT.709 full-range yuv444p in (conversion-leaf
#          stand-in; the probe converts offline with swscale)
path_flags() {
  case "$1" in
    p420)    echo "" ;;
    gbrp)    echo "--pix-fmt gbrp --profile rext" ;;
    rgbmode) echo "--profile rext --rgb-mode yuv444" ;;
    conv)    echo "--pix-fmt yuv444p --profile rext" ;;
    *) echo "unknown path $1" >&2; return 1 ;;
  esac
}
# The interpretation each path's VUI CLAIMS (color truth checks the claim).
path_interp() {
  case "$1" in
    p420)    echo "bt601-limited" ;;
    gbrp)    echo "identity-full" ;;
    rgbmode) echo "bt601-limited" ;;
    conv)    echo "bt709-full" ;;
  esac
}
path_dumpfmt() { # decoder-native raw dump format (coded plane order)
  case "$1" in
    p420) echo "yuv420p" ;;
    gbrp) echo "gbrp" ;;
    *)    echo "yuv444p" ;;
  esac
}
path_raw() { # $1 path, $2 corpus name → input raw file
  case "$1" in
    conv) echo "$WORK/$2-444.raw" ;;
    *)    echo "$WORK/$2.raw" ;;
  esac
}

# ---- corpora -------------------------------------------------------------
gen_corpora() {
  if [ ! -f "$WORK/motion.raw" ]; then
    echo "== corpus: motion (testsrc2, ${SECS}s @ ${W}x${H})"
    ffmpeg -hide_banner -loglevel error -y \
      -f lavfi -i "testsrc2=size=${W}x${H}:rate=${FPS}" \
      -t "$SECS" -pix_fmt bgr0 -f rawvideo "$WORK/motion.raw"
  fi
  if [ ! -f "$WORK/desk.raw" ]; then
    echo "== corpus: desk (gradients + scrolling text — the HS-24 shape)"
    TXT="$WORK/desk-text.txt"
    : > "$TXT"
    for i in $(seq 1 60); do
      printf 'let frame%02d = try packetizer.seal(shard: %d) // 0x%02x — the quick brown fox\n' \
        "$i" "$i" "$i" >> "$TXT"
    done
    ffmpeg -hide_banner -loglevel error -y \
      -f lavfi -i "gradients=size=${W}x${H}:rate=${FPS}:speed=0.02" \
      -vf "drawtext=textfile=${TXT}:font='DejaVu Sans Mono':fontsize=24:fontcolor=white:borderw=1:bordercolor=black:x=48:y=h-mod(t*150\,h+1600):line_spacing=8" \
      -t "$SECS" -pix_fmt bgr0 -f rawvideo "$WORK/desk.raw"
  fi
  if [ ! -f "$WORK/bars.raw" ]; then
    echo "== corpus: bars (smptehdbars, 1s — the color-truth referee)"
    ffmpeg -hide_banner -loglevel error -y \
      -f lavfi -i "smptehdbars=size=${W}x${H}:rate=${FPS}" \
      -t 1 -pix_fmt bgr0 -f rawvideo "$WORK/bars.raw"
  fi
  # conv-path inputs: BGRx → BT.709 full-range yuv444p, done offline
  # (swscale stands in for the future conversion leaf; the encode leg
  # signs exactly this conversion).
  for c in motion desk bars; do
    if [ ! -f "$WORK/$c-444.raw" ]; then
      echo "== corpus: $c-444 (BT.709 full-range yuv444p conversion)"
      ffmpeg -hide_banner -loglevel error -y \
        -f rawvideo -pixel_format bgr0 -video_size "${W}x${H}" \
        -framerate "$FPS" -i "$WORK/$c.raw" \
        -vf "scale=out_color_matrix=bt709:out_range=full:flags=accurate_rnd+full_chroma_int,format=yuv444p" \
        -f rawvideo "$WORK/$c-444.raw"
    fi
  done
  # RGB references for the PSNR half (lossless repack of the BGRx raw).
  for c in motion desk bars; do
    if [ ! -f "$WORK/$c-ref.rgb" ]; then
      ffmpeg -hide_banner -loglevel error -y \
        -f rawvideo -pixel_format bgr0 -video_size "${W}x${H}" \
        -framerate "$FPS" -i "$WORK/$c.raw" \
        -vf format=rgb24 -f rawvideo "$WORK/$c-ref.rgb"
    fi
  done
}

# ---- color machinery -----------------------------------------------------
decode_dump() { # $1 bitstream, $2 dumpfmt, $3 out raw
  ffmpeg -hide_banner -loglevel error -y -i "$1" \
    -pix_fmt "$2" -f rawvideo "$3"
}

# Re-interpret a coded-plane raw dump under a candidate matrix/range and
# emit rgb24. identity-* rereads the planes as gbrp (what an
# identity-honoring decoder does); bt* rereads as yuv444p/yuv420p and
# applies the candidate matrix via swscale.
interp_to_rgb() { # $1 dump, $2 dumpfmt, $3 candidate, $4 out rgb
  local dump="$1" fmt="$2" cand="$3" out="$4"
  case "$cand" in
    identity-full)
      ffmpeg -hide_banner -loglevel error -y \
        -f rawvideo -pixel_format gbrp -video_size "${W}x${H}" \
        -framerate "$FPS" -i "$dump" -vf format=rgb24 -f rawvideo "$out"
      ;;
    bt601-limited|bt601-full|bt709-limited|bt709-full)
      local m="${cand%%-*}" r="${cand##*-}"
      [ "$r" = "limited" ] && r=tv || r=pc
      local rfmt=yuv444p
      [ "$fmt" = "yuv420p" ] && rfmt=yuv420p
      ffmpeg -hide_banner -loglevel error -y \
        -f rawvideo -pixel_format "$rfmt" -video_size "${W}x${H}" \
        -framerate "$FPS" -i "$dump" \
        -vf "scale=in_color_matrix=${m}:in_range=${r}:flags=accurate_rnd+full_chroma_int,format=rgb24" \
        -f rawvideo "$out"
      ;;
    *) echo "unknown candidate $cand" >&2; return 1 ;;
  esac
}

psnr_rgb() { # $1 test rgb24 raw, $2 ref rgb24 raw → average RGB PSNR
  ffmpeg -hide_banner -nostats \
    -f rawvideo -pixel_format rgb24 -video_size "${W}x${H}" \
    -framerate "$FPS" -i "$1" \
    -f rawvideo -pixel_format rgb24 -video_size "${W}x${H}" \
    -framerate "$FPS" -i "$2" \
    -lavfi psnr -f null - 2>&1 |
    sed -n 's/.*average:\([0-9.inf]*\) .*/\1/p' | tail -1
}

# RGB PSNR of a bitstream against its corpus reference, decoded under
# the path's claimed interpretation.
rgb_psnr_stream() { # $1 bitstream, $2 path, $3 corpus
  local dump="$WORK/tmp-dump.raw" rgb="$WORK/tmp-cand.rgb"
  decode_dump "$1" "$(path_dumpfmt "$2")" "$dump"
  interp_to_rgb "$dump" "$(path_dumpfmt "$2")" "$(path_interp "$2")" "$rgb"
  psnr_rgb "$rgb" "$WORK/$3-ref.rgb"
  rm -f "$dump" "$rgb"
}

vui_tags() { # $1 bitstream → "profile pix_fmt space/range"
  ffprobe -hide_banner -select_streams v -show_streams "$1" 2>/dev/null |
    awk -F= '$1=="profile"{p=$2} $1=="pix_fmt"{f=$2}
             $1=="color_space"{s=$2} $1=="color_range"{r=$2}
             END{printf "%s %s %s/%s", p, f, s, r}'
}

# ---- Q1: does Rext open at all (and what does auto-select do) ------------
q1_opens() {
  echo
  echo "==== Q1: Rext open matrix (the caps check — a reject here is loud)"
  for path in gbrp rgbmode conv; do
    local flags out line
    flags="$(path_flags "$path")"
    out="$KEEP/bars-$path.hevc"
    line=$("$BIN" --raw "$(path_raw "$path" bars)" --width "$W" --height "$H" \
        --fps "$FPS" --frames "$FPS" --cq 12 --bitrate-mbps 50 \
        --out "$out" $flags 2>/dev/null | grep '^RESULT' || true)
    if [[ -z "$line" || "$line" == *open-rejected* ]]; then
      echo "  $path: OPEN-REJECTED ($line)"
      printf 'open\t%s\tREJECTED\t%s\n' "$path" "$line" >> "$RESULTS"
    else
      echo "  $path: opens — bitstream says: $(vui_tags "$out")"
      printf 'open\t%s\tOK\t%s\n' "$path" "$(vui_tags "$out")" >> "$RESULTS"
    fi
  done
  # auto-select check: gbrp WITHOUT --profile — does the wrapper pick
  # Rext on its own for 4:4:4 input?
  local out="$WORK/bars-gbrp-noprofile.hevc"
  "$BIN" --raw "$WORK/bars.raw" --width "$W" --height "$H" --fps "$FPS" \
    --frames "$FPS" --cq 12 --bitrate-mbps 50 --out "$out" \
    --pix-fmt gbrp >/dev/null 2>&1 &&
    echo "  gbrp WITHOUT profile: opens — bitstream says: $(vui_tags "$out")"
  rm -f "$out"
}

# ---- Q2a: the race (matched content + session posture) -------------------
q2_race() {
  echo
  echo "==== Q2: the color-path race (capped-CQ cq12/cap50, p4, ${FRAMES} frames)"
  printf '%-8s %-7s %9s %8s %9s %9s %8s %9s\n' \
    path corpus RGB-PSNR kbps enc-mean enc-p99 repack capacity
  for corpus in desk motion; do
    for path in p420 gbrp rgbmode conv; do
      local flags out line psnr kbps encmean encp99 repack cap
      flags="$(path_flags "$path")"
      out="$KEEP/$corpus-$path.hevc"
      line=$("$BIN" --raw "$(path_raw "$path" "$corpus")" --width "$W" \
          --height "$H" --fps "$FPS" --frames "$FRAMES" --cq 12 \
          --bitrate-mbps 50 --out "$out" $flags 2>/dev/null |
          grep '^RESULT' || true)
      if [[ -z "$line" || "$line" == *open-rejected* ]]; then
        echo "  $path/$corpus: OPEN-REJECTED"
        continue
      fi
      psnr=$(rgb_psnr_stream "$out" "$path" "$corpus")
      kbps=$(sed 's/.* kbps=\([0-9]*\) .*/\1/' <<<"$line")
      encmean=$(sed 's/.* enc_us_mean=\([0-9]*\) .*/\1/' <<<"$line")
      encp99=$(sed 's/.* enc_us_p99=\([0-9]*\) .*/\1/' <<<"$line")
      repack=$(sed 's/.* repack_us_mean=\([0-9]*\) .*/\1/' <<<"$line")
      cap=$(sed 's/.* enc_fps_capacity=\([0-9]*\).*/\1/' <<<"$line")
      printf '%-8s %-7s %9s %8s %7.2fms %7.2fms %6.2fms %8s\n' \
        "$path" "$corpus" "$psnr" "$kbps" \
        "$(bc -l <<<"$encmean/1000")" "$(bc -l <<<"$encp99/1000")" \
        "$(bc -l <<<"$repack/1000")" "$cap"
      printf 'race\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$path" "$corpus" \
        "$psnr" "$kbps" "$encmean" "$encp99" "$repack" "$cap" >> "$RESULTS"
    done
  done
}

# ---- Q2b: color truth (Stage A's candidate sweep on bars) -----------------
q2_truth() {
  echo
  echo "==== Q2b: measured color truth (bars, all candidates; winner = truth)"
  for path in gbrp rgbmode conv; do
    local bs="$KEEP/bars-$path.hevc" dump="$WORK/tmp-dump.raw"
    [ -f "$bs" ] || continue
    decode_dump "$bs" "$(path_dumpfmt "$path")" "$dump"
    echo "  -- $path (VUI claims: $(vui_tags "$bs"); claimed interp $(path_interp "$path"))"
    local best="" bestp=0
    for cand in identity-full bt601-limited bt601-full bt709-limited bt709-full; do
      local rgb="$WORK/tmp-cand.rgb" p
      interp_to_rgb "$dump" "$(path_dumpfmt "$path")" "$cand" "$rgb"
      p=$(psnr_rgb "$rgb" "$WORK/bars-ref.rgb")
      printf '     %-14s %s dB\n' "$cand" "$p"
      printf 'truth\t%s\t%s\t%s\n' "$path" "$cand" "$p" >> "$RESULTS"
      rm -f "$rgb"
      if [ "$p" != "inf" ] && (( $(bc -l <<<"$p > $bestp") )); then
        bestp="$p"; best="$cand"
      fi
      [ "$p" = "inf" ] && { bestp=999; best="$cand"; }
    done
    echo "     WINNER: $best ($bestp dB) — claimed $(path_interp "$path")"
    rm -f "$dump"
  done
}

# ---- Q3 fallback ladder: p1 at 4:4:4 --------------------------------------
q3_p1() {
  echo
  echo "==== Q3b: p1 fallback legs (motion, capped-CQ cq12/cap50)"
  for path in gbrp rgbmode conv; do
    local flags line encmean cap
    flags="$(path_flags "$path")"
    line=$("$BIN" --raw "$(path_raw "$path" motion)" --width "$W" \
        --height "$H" --fps "$FPS" --frames "$FRAMES" --cq 12 \
        --bitrate-mbps 50 --out "$WORK/tmp.hevc" --preset p1 $flags \
        2>/dev/null | grep '^RESULT' || true)
    encmean=$(sed 's/.* enc_us_mean=\([0-9]*\) .*/\1/' <<<"$line")
    cap=$(sed 's/.* enc_fps_capacity=\([0-9]*\).*/\1/' <<<"$line")
    echo "  $path/p1: enc mean $(bc -l <<<"scale=2;$encmean/1000") ms, capacity $cap fps"
    printf 'p1\t%s\t%s\t%s\n' "$path" "$encmean" "$cap" >> "$RESULTS"
    rm -f "$WORK/tmp.hevc"
  done
}

# ---- Q4: IDR/frame size books vs the FEC ceiling ---------------------------
q4_idr() {
  echo
  echo "==== Q4: IDR size distribution vs the ${CEILING} B FEC ceiling"
  echo "     (desk/text corpus, cq12/cap50, IDR forced every 60 frames,"
  echo "      $((FRAMES * 5)) frames — VBV-uncapped: this is the NATURAL demand)"
  for path in p420 gbrp rgbmode conv; do
    local flags sizes="$WORK/sizes-$path.txt"
    flags="$(path_flags "$path")"
    "$BIN" --raw "$(path_raw "$path" desk)" --width "$W" --height "$H" \
      --fps "$FPS" --frames $((FRAMES * 5)) --cq 12 --bitrate-mbps 50 \
      --idr-every 60 --sizes "$sizes" --out "$WORK/tmp.hevc" $flags \
      >/dev/null 2>&1 || { echo "  $path: leg failed"; continue; }
    rm -f "$WORK/tmp.hevc"
    # percentile math via sort(1) — mawk has no asort
    local n over mx p50 p95 dmax dp50
    n=$(awk '$2==1' "$sizes" | wc -l)
    over=$(awk -v c="$CEILING" '$2==1 && $3>=c' "$sizes" | wc -l)
    mx=$(awk '$2==1{print $3}' "$sizes" | sort -n | tail -1)
    p50=$(awk '$2==1{print $3}' "$sizes" | sort -n |
          awk -v n="$n" 'NR==int((n+1)/2){print; exit}')
    p95=$(awk '$2==1{print $3}' "$sizes" | sort -n |
          awk -v n="$n" 'NR==int(0.95*n+0.999){print; exit}')
    dmax=$(awk '$2==0{print $3}' "$sizes" | sort -n | tail -1)
    dp50=$(awk '$2==0{print $3}' "$sizes" | sort -n |
           awk -v tot="$(awk '$2==0' "$sizes" | wc -l)" \
             'NR==int((tot+1)/2){print; exit}')
    echo "  $path: $n IDRs — p50 $p50 B, p95 $p95 B, max $mx B, ≥ceiling $over; deltas p50 $dp50 B max $dmax B"
    printf 'idr\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$path" "$n" "$p50" "$p95" "$mx" "$over" "$dp50" "$dmax" >> "$RESULTS"
  done
}

# ---- Q3c: static ratchet-convergence legs ----------------------------------
q5_static() {
  echo
  echo "==== Q3c: static ratchet legs (first desk frame × 300, cq12/cap50)"
  for path in p420 gbrp rgbmode conv; do
    local flags
    flags="$(path_flags "$path")"
    echo "  -- $path"
    "$BIN" --raw "$(path_raw "$path" desk)" --width "$W" --height "$H" \
      --fps "$FPS" --static 300 --cq 12 --bitrate-mbps 50 \
      --out "$WORK/tmp.hevc" $flags 2>/dev/null |
      grep -E '^(static walk|RESULT)' | sed 's/^/     /'
    rm -f "$WORK/tmp.hevc"
  done
}

# ---- run -------------------------------------------------------------------
echo "=============== LYTE H4 V-1 — NVENC REXT 4:4:4 PROBE — $(date +%F)$(git -C "$(dirname "$0")" rev-parse --short HEAD 2>/dev/null | sed 's/^/ @ /') ==============="
echo "host: $(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null || echo 'no nvidia-smi')"
echo "ffmpeg: $(ffmpeg -version 2>/dev/null | head -1)"
gen_corpora
q1_opens
q2_race
q2_truth
q3_p1
q4_idr
q5_static
echo
echo "results at $RESULTS; V-2 bitstreams at $KEEP/ — corpora in $WORK are"
echo "~16 GB, remove after harvest. Ceiling reference: ${CEILING} B (HS-25)."
echo "=============================================================================="

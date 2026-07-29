#!/usr/bin/env bash
# corpus-harness.sh (H4 V-3) — the §7 corpus harness as a standing
# instrument (docs/20260720-191701-lyte-protocol-image-quality.md §7,
# H4 plan slice V-3). The 4:4:4 acceptance gate and the regression
# guard for EVERY later recipe change: one script, one summary block,
# the R5/Q-1 "cannot rot" doctrine.
#
# Runs ON THE MAC, orchestrating the reference host (pup) over ssh —
# offline encode legs ONLY: no capture, no wire, no session, no
# secrets contact; safe to run next to the owner's standing 41151
# loop. The pipeline is the real one at both ends:
#
#   lyte-cli corpus-gen        the deterministic in-repo corpus
#                              (hash-frozen by root gate tests)
#   lyte-encode-check @ pup    the production CHevcEncode leaf, the
#                              shipped session recipe (p4, capped-CQ
#                              cq12 / cap 50 Mbps), --static N — the
#                              ratchet mechanism in miniature
#   lyte-cli decode-probe      VideoToolbox through the production
#                              construction (AnnexBAccessUnits →
#                              VideoRenderFactory), hardware REQUIRED,
#                              BGRA readback (V-2's tap)
#   lyte-cli corpus-gate       the §7 math, thresholds pinned in code
#                              (2026-07-29 bar-vs-path ruling applied):
#                              text-region RGB PSNR (per-channel min)
#                              ≥40 active / ≥45 post-ratchet, SSIM
#                              ≥0.995 on (a)–(c), range patches
#                              exact+1 limited601, gratings ≤±4 codes,
#                              convergence ≤180 frames, golden diff
#
# Legs by chroma mode:
#   420  today's shipped path — measured as the REFERENCE ROW (gates
#        evaluated but never failing: the baseline the pillar says to
#        record alongside every 4:4:4 report). Banked FIRST per V-3.
#        Rides the Good-tier floor (cq12).
#   444  the shipped Best-tier posture (owner decisions 1+2, V-4 =
#        EncoderRecipe.best444): rgb_mode 601-limited via
#        --profile rext --rgb-mode yuv444, at the Best-mode floor
#        (cq4 — the V-4 floor race's knee). Gates ENFORCE. Two bars
#        are conversion-floored, not floor-tunable (V-4 measured the
#        asymptote at transparent coding): the 601-limited round trip
#        caps text at ~46–47 dB (bar ≥50) and the green-magenta
#        grating at ±3 (bar ≤±2) — their status pends the owner's
#        bar-vs-path ruling; every other 444 gate must PASS.
#
# Offline scope, stated honestly: the ratchet gate here is the
# capped-CQ convergence walk (byte-stable ≤3 s) from the encoder's
# size books; the live-session halves — "zero frames sent after
# convergence" and ratchet-bytes-vs-surplus — need a Work-mode wire
# session and wait for V-4/J-G4a.
#
# Goldens: decoded post-ratchet PNGs of corpus (a) live in
# Goldens/corpus/ (committed). GOLDEN=check diffs against them
# (non-empty diff = human looks, reported not failed); GOLDEN=write
# (re)writes them — do that only when a recipe change is INTENDED to
# move the pixels, and say so in the commit.
#
# usage: corpus-harness.sh [420|444|both]     (default: both)
# env: PUP, BIN (remote lyte-encode-check), CLI (local lyte-cli),
#      STATIC, CQ420/CQ444 (per-tier floors; CQ overrides BOTH for
#      A/B hunts), CAP_MBPS, GOLDEN=check|write|skip, KEEP (=1 keeps
#      remote artifacts), LOCAL, REMOTE.

set -uo pipefail

ssh() {
  command ssh -o ConnectTimeout=10 \
    -o ServerAliveInterval=5 -o ServerAliveCountMax=6 "$@"
}

LEGS="${1:-both}"
case "$LEGS" in 420|444|both) ;; *) echo "usage: corpus-harness.sh [420|444|both]"; exit 2 ;; esac

PUP="${PUP:-pup}"
BIN="${BIN:-\$HOME/src/lyte-host/.build/debug/lyte-encode-check}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLI="${CLI:-$REPO_ROOT/.build/debug/lyte-cli}"
GOLDEN_DIR="$REPO_ROOT/Goldens/corpus"
STATIC="${STATIC:-240}"          # 4 s @60 — room to prove the ≤180-frame bar
# Per-tier ratchet floors, mirroring the shipped recipes: Good rides
# spec §3's cq12 (EncoderRecipe.sessionDefault), Best rides the V-4
# floor race's knee cq4 (EncoderRecipe.best444). CQ= overrides both
# for a single-knob A/B hunt.
CQ420="${CQ:-${CQ420:-12}}"
CQ444="${CQ:-${CQ444:-4}}"
CAP_MBPS="${CAP_MBPS:-50}"       # the shipped session posture (HS-24/HS-25)
GOLDEN="${GOLDEN:-check}"
KEEP="${KEEP:-0}"
LOCAL="${LOCAL:-/tmp/corpus-harness}"
REMOTE="${REMOTE:-corpus-harness}"   # under $HOME on pup

[ -x "$CLI" ] || { echo "no lyte-cli at $CLI (swift build first)"; exit 1; }
ssh -o ConnectTimeout=8 "$PUP" "test -x $BIN" \
  || { echo "preflight failed: $PUP unreachable or no lyte-encode-check at $BIN"; exit 1; }
case "$GOLDEN" in check|write|skip) ;; *) echo "GOLDEN wants check|write|skip"; exit 2 ;; esac

mkdir -p "$LOCAL/enc" "$LOCAL/dec"
[ "$GOLDEN" = write ] && mkdir -p "$GOLDEN_DIR"

# ---- the corpus (regenerated every run — determinism is a gate test) ------
echo "== corpus: generating (deterministic, hash-frozen)"
"$CLI" corpus-gen --out "$LOCAL/corpus" > "$LOCAL/corpus-gen.log" \
  || { echo "corpus-gen FAILED:"; tail -5 "$LOCAL/corpus-gen.log"; exit 1; }
# Top-level keys sit at 2-space indent, frame names at 6 — deeper
# rect/patch keys ("width", "name") must not shadow them.
W=$(sed -n 's/^  "width" : \([0-9]*\).*/\1/p' "$LOCAL/corpus/manifest.json")
H=$(sed -n 's/^  "height" : \([0-9]*\).*/\1/p' "$LOCAL/corpus/manifest.json")
FRAMES=$(sed -n 's/^      "name" : "\(.*\)".*/\1/p' "$LOCAL/corpus/manifest.json")
echo "   ${W}x${H}; frames: $(echo $FRAMES | tr '\n' ' ')"

echo "== corpus: sync → $PUP:~/$REMOTE/corpus/"
ssh "$PUP" "mkdir -p ~/$REMOTE/corpus"
rsync -a "$LOCAL/corpus/"*.raw "$PUP:$REMOTE/corpus/" \
  || { echo "rsync to $PUP failed"; exit 1; }

# ---- per-leg machinery -----------------------------------------------------
leg_flags() { # chroma → extra lyte-encode-check flags
  case "$1" in
    420) echo "" ;;
    444) echo "--profile rext --rgb-mode yuv444" ;;  # owner decision 2
  esac
}

run_leg() { # $1 = chroma → writes $LOCAL/gates-$1.log, appends TABLE rows
  local chroma="$1" flags mode cq
  flags="$(leg_flags "$chroma")"
  mode=$([ "$chroma" = 444 ] && echo work || echo baseline)
  cq=$([ "$chroma" = 444 ] && echo "$CQ444" || echo "$CQ420")
  local gatelog="$LOCAL/gates-$chroma.log"
  local enclog="$LOCAL/encode-$chroma.log"
  : > "$gatelog"; : > "$enclog"
  local legfail=0

  echo
  echo "== leg $chroma (cq$cq; $mode: gates $([ "$mode" = work ] && echo ENFORCE || echo report as reference))"
  for name in $FRAMES; do
    local base="$name-$chroma"
    # 1. encode on pup — the production leaf, static-repeat mode.
    ssh "$PUP" "$BIN --raw ~/$REMOTE/corpus/$name.raw --width $W --height $H \
        --fps 60 --static $STATIC --cq $cq --bitrate-mbps $CAP_MBPS \
        --out ~/$REMOTE/$base.hevc --sizes ~/$REMOTE/$base.sizes $flags" \
        >> "$enclog" 2>&1 \
      || { echo "   $name: ENCODE FAILED (see $enclog)"; tail -3 "$enclog" | sed 's/^/     /'; legfail=1; continue; }
    rsync -a "$PUP:$REMOTE/$base.hevc" "$PUP:$REMOTE/$base.sizes" "$LOCAL/enc/" \
      || { echo "   $name: fetch failed"; legfail=1; continue; }

    # 2. decode on the Mac — VideoToolbox, hardware required, BGRA tap.
    # Frames: 0 = the cold VBV-constrained IDR (reported), 59 = active
    # phase 1 s into the walk (gated ≥40), last = post-ratchet (gated).
    "$CLI" decode-probe "$LOCAL/enc/$base.hevc" --pixel-format bgra \
        --require-hardware --dump "$LOCAL/dec/$base.bgra" \
        --dump-frames 0,59,last > "$LOCAL/dec/$base.log" 2>&1 \
      || { echo "   $name: DECODE FAILED (see $LOCAL/dec/$base.log)"; legfail=1; continue; }

    # 3. the §7 gates (thresholds pinned in code).
    local golden_args=()
    if [ "$GOLDEN" = write ] && [[ "$name" == text-* ]]; then
      golden_args+=(--write-golden "$GOLDEN_DIR/$base.png")
    elif [ "$GOLDEN" = check ] && [ -f "$GOLDEN_DIR/$base.png" ]; then
      golden_args+=(--golden "$GOLDEN_DIR/$base.png")
    fi
    # Both legs ship 601-limited today (Stage A's 4:2:0 and owner
    # decision 2's rgb_mode 4:4:4) — exact range is named-and-queued.
    "$CLI" corpus-gate --manifest "$LOCAL/corpus/manifest.json" \
        --frame "$name" --decoded "$LOCAL/dec/$base.bgra" \
        --chroma "$chroma" --mode "$mode" --range-posture limited601 \
        --sizes "$LOCAL/enc/$base.sizes" \
        ${golden_args+"${golden_args[@]}"} >> "$gatelog" 2>&1
    local rc=$?
    [ $rc -ne 0 ] && legfail=1
    grep -E "^(GATE|info|golden)" "$gatelog" | grep " $name/" | tail -20 | sed 's/^/   /'
  done
  return $legfail
}

# One table row per frame from the gate log's RESULT lines.
leg_table() { # $1 = chroma
  awk -v chroma="$1" '
    /^RESULT / {
      delete kv
      for (i = 2; i <= NF; i++) { split($i, a, "="); kv[a[1]] = a[2] }
      if (kv["chroma"] != chroma) next
      special = "-"
      if (kv["grating_max"] != "") special = "grating ±" kv["grating_max"]
      if (kv["patch_max"] != "")   special = "patch ±" kv["patch_max"]
      text = (kv["text_active_db"] != "") \
        ? kv["text_active_db"] "/" kv["text_conv_db"] : "-"
      split_db = (kv["text_white_db"] != "") \
        ? kv["text_white_db"] "/" kv["text_syntax_db"] : "-"
      idr = (kv["idr_b"] != "") ? kv["idr_b"] "/" kv["keepalive_b"] : "-"
      printf "%-10s %-5s %6s %9s/%-9s %11s %13s %8s %11s %5s %12s %6s %s\n",
        kv["frame"], chroma, (kv["idr_db"] != "" ? kv["idr_db"] : "-"),
        kv["full_active_db"], kv["full_conv_db"],
        text, split_db, (kv["ssim"] != "" ? kv["ssim"] : "-"), special,
        "cv" kv["converge_frame"], idr,
        (kv["golden"] != "" ? kv["golden"] : "-"), kv["verdict"]
    }' "$LOCAL/gates-$1.log"
}

RC420="-" RC444="-"
[ "$LEGS" != 444 ] && { run_leg 420; RC420=$?; }
[ "$LEGS" != 420 ] && { run_leg 444; RC444=$?; }

# ---- hygiene ---------------------------------------------------------------
[ "$KEEP" = 1 ] || ssh "$PUP" "rm -rf ~/$REMOTE"

# ---- the summary block -----------------------------------------------------
SHA=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "?")
verdict() { case "$1" in -) echo "not run" ;; 0) echo PASS ;; *) echo FAIL ;; esac; }
SUMMARY=$(
  echo "=============== LYTE §7 CORPUS HARNESS — $(date +%Y-%m-%d) @ $SHA ==============="
  echo "recipe: sessionDefault (p4) — 420 leg cq$CQ420, 444 leg (best444) cq$CQ444 / cap $CAP_MBPS Mbps, static x$STATIC @ ${W}x${H}"
  echo "encode: $PUP production C leaf · decode: VideoToolbox HARDWARE (required) · math: pinned in code"
  printf "%-10s %-5s %6s %9s/%-9s %11s %13s %8s %11s %5s %12s %6s %s\n" \
    frame chroma idr-dB "act@1s-dB" conv-dB "text a/c dB" "white/syn dB" SSIM special cv "idr/keep B" golden verdict
  [ "$LEGS" != 444 ] && leg_table 420
  [ "$LEGS" != 420 ] && leg_table 444
  echo "bars: text ≥40 active(@1 s) / ≥45 conv (per-ch min, 2026-07-29 ruling) · SSIM ≥0.995 · gratings ≤±4 · patches exact+1 (limited601, owner decision 2;"
  echo "      byte-exact named-and-queued) · converge ≤180 fr · cold IDR reported unmetered (VBV posture, the ratchet heals it)"
  echo "420 rows are the REFERENCE (recorded alongside, gates never fail it — gratings CANNOT pass there, which is the point)"
  echo "offline scope: live-ratchet halves (zero frames post-convergence, bytes ≤ surplus) wait for V-4/J-G4a"
  echo "verdict: 420 $(verdict "$RC420") · 444 $(verdict "$RC444")   (logs: $LOCAL/gates-*.log, encode-*.log)"
  echo "=============================================================================="
)
echo
echo "$SUMMARY"
echo "$SUMMARY" > "$LOCAL/summary.txt"
echo "(saved to $LOCAL/summary.txt)"
[ "$RC444" != 1 ] && [ "$RC420" != 1 ]

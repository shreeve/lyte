#!/usr/bin/env bash
# quality-probe.sh (Q-1) — the video-quality probe as a standing
# instrument: the supremacy plan's R5, mechanizing the method of
# docs/20260728-164746-lyte-video-quality-probe.md so it can never
# need rediscovering again (the probe's method had to be re-derived
# once from a month-old gate — this script is what kills that rot).
#
# Runs ON THE MAC (the client end must hold up the wire leg's glass),
# orchestrating the Linux host over ssh. Three legs, one summary block
# — the BEAUTY BAR (the standing table lives in HANDOFF.md; this
# prints the row to paste into it):
#
#   static  LYTE_DUMP_RAW file-mode leg: 60 s capped-CQ ratchet encode
#           of the host desktop; per-frame luma PSNR of the decoded
#           stream against the final retained raw frame (ffmpeg psnr,
#           looped raw reference, both sides yuv420p). The converged
#           number is the series MAX (mid-run frames differ from the
#           end-of-run reference wherever the desktop moved — content
#           drift, not codec softness).             bar: ≥ 50 dB
#   motion  N × 6 s file-mode runs against a WINDOWED Wayland-native
#           testsrc2 1600x1000@60 window (fullscreen -fs starves the
#           Mutter screencast — HS-25; Xwayland-over-ssh renders ~5 fps
#           and fakes a static leg — HS-24; the damage-rate preflight
#           below catches both). The dump is last-frame-only, so each
#           run yields ONE valid pair; the median of N last-frame
#           PSNRs is the number.                    bar: ≥ 55 dB
#   wire    the A/B pair on a live session (host --wire-listen, client
#           wire-view --audio): 150 s heavy motion, policy ARMED, then
#           the --no-vbv-reconfigure twin. From the armed leg: glass
#           fps p50 (per-second decoded deltas — wire-view logs no
#           per-frame presentation stamps; per-second granularity,
#           honestly labeled), IDR rate/min, standing-rate directive
#           churn (a directive with no estimator move since the last
#           one — HS-22a's "silent above the boundary" mechanized),
#           and wire frame loss (host frames ingested − client
#           decoded − skipped).
#           bars: fps ≥ 55 · IDR ≤ 2/min · churn = 0 · loss ≤ 1
#
# Safety rails baked in (the HS-25 playbook): every harness host runs
# --no-advertise on a 41183+ port; the owner's 41151 loop is never
# touched; test patterns are windowed and killed; the three host
# secrets are sha256'd before and after (noise_static.key +
# paired_clients must be byte-identical; portal_token rotates BY
# DESIGN on every host run — the restore-token chain).
#
# Companion instrument: Host/Scripts/encoder-ab.sh answers "which
# recipe" (rerun it per recipe question, always with the desk/text
# corpus in the race); this probe answers "did the glass get better".
#
# env overrides: PUP (ssh alias), PUP_ADDR, HOST_BIN (remote path),
# CLI (local lyte-cli), PORT, CAP_MBPS, STATIC_SECS, MOTION_RUNS,
# MOTION_SECS, WIRE_SECS, KEEP (=1 keeps raw/hevc artifacts on pup).

set -uo pipefail

# pup drops off-network spontaneously sometimes (HANDOFF operational
# fact) — bounded connect timeouts + keepalives turn a mid-run drop
# into a loud failure in seconds instead of a wedged instrument (the
# default TCP posture took ~15 min to surface the 2026-07-28 drop).
ssh() {
  command ssh -o ConnectTimeout=10 \
    -o ServerAliveInterval=5 -o ServerAliveCountMax=6 "$@"
}

PUP="${PUP:-pup}"
PUP_ADDR="${PUP_ADDR:-10.0.0.249}"
HOST_BIN="${HOST_BIN:-\$HOME/src/lyte-host/.build/debug/lyte-host}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLI="${CLI:-$REPO_ROOT/.build/debug/lyte-cli}"
PORT="${PORT:-41183}"
CAP_MBPS="${CAP_MBPS:-50}"
STATIC_SECS="${STATIC_SECS:-60}"
MOTION_RUNS="${MOTION_RUNS:-12}"
MOTION_SECS="${MOTION_SECS:-6}"
WIRE_SECS="${WIRE_SECS:-150}"
KEEP="${KEEP:-0}"
W=1600 H=1000 FPS=60

BAR_STATIC=50 BAR_MOTION=55 BAR_FPS=55 BAR_IDR_MIN=2 BAR_LOSS=1

WORK='$HOME/qprobe'   # remote, expanded on pup
LOCAL=/tmp/qprobe-local
RENV='XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus'
FFENV="$RENV WAYLAND_DISPLAY=wayland-0 SDL_VIDEODRIVER=wayland"

[ "$PORT" != 41151 ] || { echo "REFUSED: 41151 is the owner's standing loop"; exit 1; }
[ -x "$CLI" ] || { echo "no lyte-cli at $CLI (Scripts/build-cli.sh first)"; exit 1; }
ssh -o ConnectTimeout=8 "$PUP" "test -x $HOST_BIN && command -v ffmpeg >/dev/null && command -v ffplay >/dev/null" \
  || { echo "preflight failed: $PUP unreachable, or $HOST_BIN / ffmpeg / ffplay missing there"; exit 1; }

mkdir -p "$LOCAL"
ssh "$PUP" "mkdir -p $WORK"

FFPLAY_PID="" HOST_PID=""
cleanup() {
  [ -n "$FFPLAY_PID" ] && ssh "$PUP" "kill $FFPLAY_PID 2>/dev/null" || true
  [ -n "$HOST_PID" ] && ssh "$PUP" "kill $HOST_PID 2>/dev/null" || true
}
trap cleanup EXIT

# ---- secrets baseline (rails, not paranoia) -----------------------------
secrets() {
  ssh "$PUP" 'sha256sum ~/.config/lyte-host/noise_static.key ~/.config/lyte-host/paired_clients ~/.config/lyte-host/portal_token' \
    | awk '{ print $1 }'
}
SECRETS_BEFORE=$(secrets)

# ---- helpers ------------------------------------------------------------
start_ffplay() { # heavy-motion window on the host desktop, WINDOWED
  FFPLAY_PID=$(ssh "$PUP" "$FFENV nohup ffplay -loglevel error -f lavfi \
    -i 'testsrc2=size=${W}x${H}:rate=${FPS}' >/dev/null 2>&1 & echo \$!")
  sleep 3
}
stop_ffplay() {
  [ -n "$FFPLAY_PID" ] && ssh "$PUP" "kill $FFPLAY_PID 2>/dev/null" || true
  FFPLAY_PID=""
}

file_leg() { # $1=name $2=seconds → host log at $WORK/$1.log
  ssh "$PUP" "LYTE_DUMP_RAW=$WORK/$1.raw $RENV $HOST_BIN --backend portal \
    --ratchet --bitrate-mbps $CAP_MBPS --seconds $2 \
    --out $WORK/$1.hevc > $WORK/$1.log 2>&1"
}

psnr_numbers() { # $1=name → "first max last n" (luma dB; inf→999)
  ssh "$PUP" "NAME=$1 WORK=$WORK FPS=$FPS bash -s" <<'REMOTE'
set -e
cd "$(eval echo "$WORK")"
line=$(grep 'raw reference dumped:' "$NAME.log")
bytes=$(sed 's/.*(\([0-9]*\) bytes.*/\1/' <<<"$line")
stride=$(sed 's/.*stride \([0-9]*\)).*/\1/' <<<"$line")
res=$(grep -o 'resolution [0-9]*x[0-9]*' "$NAME.log" | head -1)
CW=$(sed 's/resolution \([0-9]*\)x.*/\1/' <<<"$res")
CH=$(sed 's/.*x\([0-9]*\)$/\1/' <<<"$res")
SW=$((stride / 4)); SH=$((bytes / stride))
ffmpeg -hide_banner -loglevel error -nostats \
  -stream_loop -1 -f rawvideo -pixel_format bgr0 \
  -video_size ${SW}x${SH} -framerate "$FPS" -i "$NAME.raw" \
  -i "$NAME.hevc" \
  -lavfi "[0:v]crop=${CW}:${CH}:0:0,format=yuv420p[ref];[1:v]format=yuv420p[dec];[dec][ref]psnr=stats_file=$NAME.psnr:shortest=1" \
  -f null - </dev/null
awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^psnr_y:/) {
         v = substr($i, 8) + 0; if ($i == "psnr_y:inf") v = 999
         if (NR == 1) first = v; if (v > max) max = v; last = v; n++ } }
     END { printf "%.2f %.2f %.2f %d\n", first, max, last, n }' "$NAME.psnr"
REMOTE
}

median() { sort -n | awk '{ a[NR] = $1 } END { print (NR ? a[int((NR + 1) / 2)] : 0) }'; }

# ---- leg 1: static ------------------------------------------------------
echo "== static leg (${STATIC_SECS}s file-mode, capped-CQ at ${CAP_MBPS} Mbps)"
file_leg static "$STATIC_SECS" || { echo "static leg FAILED:"; ssh "$PUP" "tail -5 $WORK/static.log"; exit 1; }
read -r S_FIRST S_MAX _ S_N <<<"$(psnr_numbers static)"
S_DAMAGE=$(ssh "$PUP" "grep -m1 '^done:' $WORK/static.log" | sed 's/.*(\([0-9]*\) damage.*/\1/')
echo "   converged (max) $S_MAX dB, opening IDR $S_FIRST dB — $S_N frames, $S_DAMAGE damage"

# ---- leg 2: motion ------------------------------------------------------
echo "== motion legs ($MOTION_RUNS × ${MOTION_SECS}s, windowed testsrc2 ${W}x${H}@${FPS})"
start_ffplay
MOTION_PSNRS=""
for i in $(seq 1 "$MOTION_RUNS"); do
  file_leg "motion$i" "$MOTION_SECS" || { echo "motion run $i FAILED:"; ssh "$PUP" "tail -5 $WORK/motion$i.log"; stop_ffplay; exit 1; }
  if [ "$i" = 1 ]; then
    # HS-24's environmental trap: a frozen/Xwayland pattern fakes a
    # static leg. Damage supply must look like real motion.
    DMG=$(ssh "$PUP" "grep -m1 '^done:' $WORK/motion1.log" | sed 's/.*(\([0-9]*\) damage.*/\1/')
    if [ "$((DMG / MOTION_SECS))" -lt 40 ]; then
      echo "ABORT: motion damage supply is $((DMG / MOTION_SECS)) fps (<40) —"
      echo "the test pattern is not driving the compositor (frozen ffplay,"
      echo "Xwayland, or fullscreen starvation). Nothing to measure."
      stop_ffplay; exit 1
    fi
  fi
  read -r _ _ LAST _ <<<"$(psnr_numbers "motion$i")"
  MOTION_PSNRS="$MOTION_PSNRS$LAST"$'\n'
  echo "   run $i: last-frame PSNR $LAST dB"
done
stop_ffplay
M_MEDIAN=$(printf '%s' "$MOTION_PSNRS" | median)
M_MIN=$(printf '%s' "$MOTION_PSNRS" | sort -n | head -1)
M_MAX=$(printf '%s' "$MOTION_PSNRS" | sort -n | tail -1)
echo "   median $M_MEDIAN dB (${M_MIN}–${M_MAX} over $MOTION_RUNS runs)"

# ---- leg 3: the wire A/B ------------------------------------------------
wire_leg() { # $1=name $2=extra-host-flags → logs at $WORK/wire-$1.log + $LOCAL/wire-$1-client.log
  start_ffplay
  HOST_PID=$(ssh "$PUP" "$RENV nohup $HOST_BIN --wire-listen $PORT \
    --no-advertise --ratchet --seconds $WIRE_SECS $2 \
    > $WORK/wire-$1.log 2>&1 & echo \$!")
  # The host runs its Rext 4:4:4 self-probe BEFORE it listens (V-4) —
  # a blind sleep loses the race and wire-view gives up after 5
  # attempts (measured at HS-33). Wait for the listening line, bounded.
  for _ in $(seq 1 20); do
    ssh "$PUP" "grep -q 'awaiting client handshake' $WORK/wire-$1.log 2>/dev/null" && break
    sleep 1
  done
  "$CLI" wire-view "$PORT" --host "$PUP_ADDR" --audio \
    --duration $((WIRE_SECS + 45)) > "$LOCAL/wire-$1-client.log" 2>&1
  for _ in $(seq 1 30); do
    ssh "$PUP" "kill -0 $HOST_PID 2>/dev/null" || break
    sleep 1
  done
  ssh "$PUP" "kill $HOST_PID 2>/dev/null" || true
  HOST_PID=""
  stop_ffplay
  ssh "$PUP" "cat $WORK/wire-$1.log" > "$LOCAL/wire-$1-host.log"
}

parse_wire() { # $1=name → sets R_* globals from the leg's two logs
  local hlog="$LOCAL/wire-$1-host.log" clog="$LOCAL/wire-$1-client.log"
  R_FRAMES=$(grep -m1 'frames →' "$hlog" | sed 's/session: \([0-9]*\) frames.*/\1/')
  R_IDR=$(grep -m1 '^done:' "$hlog" | sed 's/.*(\([0-9]*\) IDR).*/\1/')
  R_SECS=$(grep -m1 '^done:' "$hlog" | sed 's/.*over \([0-9.]*\)s.*/\1/')
  R_DIRECTIVES=$(grep -m1 '^encoder-vbv:' "$hlog" | sed 's/encoder-vbv: \([0-9]*\) directives.*/\1/')
  R_IDR_MIN=$(awk -v i="$R_IDR" -v s="$R_SECS" 'BEGIN { printf "%.1f", i * 60 / s }')
  # HS-22a mechanized: every directive must be paired with at least one
  # estimator move since the previous directive — a directive at a
  # standing rate is clean-path churn.
  R_CHURN=$(awk '/^rate: / { m++ }
                 /^encoder: rate reconfigure/ { if (!m) bad++; m = 0 }
                 END { print bad + 0 }' "$hlog")
  # The estimator line reads `delivery X kbps (burst max Y, belief Z)` —
  # capture through the close paren, and shout if the shape ever drifts
  # again (this grep rotted silently once, 2026-07-30).
  R_DELIVERY=$(grep -o 'delivery [^)]*)' "$hlog" | head -1)
  [ -n "$R_DELIVERY" ] || R_DELIVERY="*** GREP ROTTED — estimator line shape changed, fix parse_wire ***"
  # Client side: decoded/skipped totals + per-second cadence.
  local final
  final=$(grep 'render: ' "$clog" | tail -1)
  R_DECODED=$(sed -E 's/.*render: ([0-9]+) decoded.*/\1/' <<<"$final")
  R_SKIPPED=$(sed -E 's/.*decoded, ([0-9]+) skipped.*/\1/' <<<"$final")
  R_MISSING=$(grep 'wire: ' "$clog" | tail -1 | sed -E 's/.*, ([0-9]+) missing.*/\1/')
  R_DGRAMS=$(grep 'wire: ' "$clog" | tail -1 | sed -E 's/.*wire: ([0-9]+) dg.*/\1/')
  R_LOSS=$((R_FRAMES - R_DECODED - R_SKIPPED))
  # Cadence from the per-second ticks only (the "…" prefix; the final
  # summary block repeats the totals and must not add a delta). Trim
  # the ramp (first 5 s) and the teardown tail (last 3 s).
  R_FPS_P50=$(grep '^…' "$clog" | grep 'render: ' \
    | sed -E 's/.*render: ([0-9]+) decoded.*/\1/' \
    | awk 'NR > 1 { print $1 - prev } { prev = $1 }' \
    | awk '{ a[NR] = $1 } END { for (i = 6; i <= NR - 3; i++) print a[i] }' \
    | median)
}

echo "== wire leg A (policy armed, ${WIRE_SECS}s heavy motion, port $PORT)"
wire_leg armed ""
parse_wire armed
A_FRAMES=$R_FRAMES A_IDR=$R_IDR A_IDR_MIN=$R_IDR_MIN A_DIRECTIVES=$R_DIRECTIVES
A_CHURN=$R_CHURN A_LOSS=$R_LOSS A_FPS=$R_FPS_P50 A_MISSING=$R_MISSING
A_DGRAMS=$R_DGRAMS A_DELIVERY=$R_DELIVERY A_SECS=$R_SECS
echo "   fps p50 $A_FPS, IDR $A_IDR ($A_IDR_MIN/min), directives $A_DIRECTIVES (churn $A_CHURN), loss $A_LOSS"

echo "== wire leg B (twin --no-vbv-reconfigure, ${WIRE_SECS}s, same content)"
wire_leg twin "--no-vbv-reconfigure"
parse_wire twin
T_IDR=$R_IDR T_IDR_MIN=$R_IDR_MIN T_FPS=$R_FPS_P50
echo "   fps p50 $T_FPS, IDR $T_IDR ($T_IDR_MIN/min)"

# ---- hygiene ------------------------------------------------------------
SECRETS_AFTER=$(secrets)
KEY_OK=$([ "$(sed -n 1p <<<"$SECRETS_BEFORE")" = "$(sed -n 1p <<<"$SECRETS_AFTER")" ] \
  && [ "$(sed -n 2p <<<"$SECRETS_BEFORE")" = "$(sed -n 2p <<<"$SECRETS_AFTER")" ] \
  && echo "byte-identical" || echo "*** CHANGED — INVESTIGATE ***")
TOKEN_NOTE=$([ "$(sed -n 3p <<<"$SECRETS_BEFORE")" = "$(sed -n 3p <<<"$SECRETS_AFTER")" ] \
  && echo "unchanged" || echo "rotated (by design)")
[ "$KEEP" = 1 ] || ssh "$PUP" "rm -f $WORK/*.raw $WORK/*.hevc"

# ---- the summary block --------------------------------------------------
pass() { awk -v v="$1" -v b="$2" -v op="$3" 'BEGIN {
  if (op == ">=") print (v >= b ? "PASS" : "FAIL")
  else print (v <= b ? "PASS" : "FAIL") }'; }
P1=$(pass "$S_MAX" $BAR_STATIC ">="); P2=$(pass "$M_MEDIAN" $BAR_MOTION ">=")
P3=$(pass "$A_FPS" $BAR_FPS ">=");    P4=$(pass "$A_IDR_MIN" $BAR_IDR_MIN "<=")
P5=$(pass "$A_CHURN" 0 "<=");         P6=$(pass "$A_LOSS" $BAR_LOSS "<=")
SHA=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "?")

SUMMARY=$(cat <<EOF
=============== LYTE QUALITY PROBE — $(date +%Y-%m-%d) @ $SHA ===============
static  : converged luma PSNR $S_MAX dB (opening IDR $S_FIRST; $S_N fr, $S_DAMAGE damage)   [bar ≥$BAR_STATIC]  $P1
motion  : last-frame PSNR median $M_MEDIAN dB (${M_MIN}–${M_MAX}, $MOTION_RUNS runs @ cap $CAP_MBPS Mbps)   [bar ≥$BAR_MOTION]  $P2
wire A  : glass fps p50 $A_FPS (${A_SECS}s armed heavy motion)   [bar ≥$BAR_FPS]  $P3
          IDR $A_IDR = $A_IDR_MIN/min   [bar ≤$BAR_IDR_MIN/min]  $P4
          standing-rate directive churn $A_CHURN (of $A_DIRECTIVES directives)   [bar =0]  $P5
          frame loss $A_LOSS of $A_FRAMES emitted ($A_MISSING/$A_DGRAMS dgrams missing)   [bar ≤$BAR_LOSS]  $P6
wire B  : twin IDR $T_IDR = $T_IDR_MIN/min, fps p50 $T_FPS — armed overhead $((A_IDR - T_IDR)) IDR (HS-22c bar ≤3)
receipts: estimator $A_DELIVERY
secrets : noise_static.key + paired_clients $KEY_OK; portal_token $TOKEN_NOTE
BEAUTY BAR ROW: | $(date +%Y-%m-%d) @ $SHA | $S_MAX $P1 | $M_MEDIAN $P2 | $A_FPS $P3 | $A_IDR_MIN $P4 | $A_CHURN $P5 | $A_LOSS $P6 |
==============================================================================
EOF
)
echo "$SUMMARY"
echo "$SUMMARY" > /tmp/quality-probe-summary.txt
echo "(saved to /tmp/quality-probe-summary.txt; host logs on $PUP at ~/qprobe/, client logs in $LOCAL)"

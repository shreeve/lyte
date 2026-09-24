#!/usr/bin/env python3
"""Motion-source preflight for benchmark-app.sh.

Judges the pup motion presenter's own log before Lyte is measured: the
authored frames must reach the compositor at exact dimensions and, for a
moving source, at a clean 60 Hz cadence. A failing source makes every Lyte
number meaningless, so the benchmark stops here.

Usage: motion_preflight.py SOURCE_LOG SUMMARY_JSON WIDTH HEIGHT SCALE [FREEZE]

Always writes SUMMARY_JSON (the benchmark's provenance step reads it) and
exits 0 on pass, 1 on fail.
"""

import json
import math
import sys
from pathlib import Path

PERIOD_US = 1_000_000 / 60
WARM_SAMPLES = 180
MIN_SAMPLES = 120
MAX_GAP_P99_MS = 25
MAX_PHASE_DRIFT_P99_MS = 8
# Reported when nothing was measurable: huge but still a JSON number, so the
# analyzer's numeric comparisons fail it cleanly.
UNMEASURED_MS = 1_000_000_000


def percentile(values, rank):
    values = sorted(values)
    return values[max(0, math.ceil(rank / 100 * len(values)) - 1)]


def dimensions_exact(rows, width, height, scale):
    return all(
        row["textureWidth"] == width
        and row["textureHeight"] == height
        and abs(row["allocationWidthPoints"] * scale - width) <= 1
        and abs(row["allocationHeightPoints"] * scale - height) <= 1
        for row in rows
    )


def judge(events, width, height, scale, freeze=None):
    """Returns the summary dict; its "pass" key is the verdict."""
    ticks = [row for row in events if row.get("event") == "sourceTick"]
    base = {"width": width, "height": height, "logicalScale": scale}

    if freeze is not None:
        # A frozen presenter proves the single authored frame reached the
        # glass at exact dimensions; cadence has no meaning.
        if not ticks:
            return {**base, "pass": False, "error": "frozen source never ticked"}
        if any(row["frameID"] != freeze for row in ticks):
            return {**base, "pass": False,
                    "error": "frozen source presented a foreign frame"}
        presented = [
            row for row in events
            if row.get("event") == "presentation"
            and row.get("frameID") == freeze
            and row.get("actualPresentationMicroseconds", 0) > 0
        ]
        exact = dimensions_exact(ticks, width, height, scale)
        return {
            **base,
            "samples": len(ticks),
            "actualPresentations": len(presented),
            "allocationWidthPoints": ticks[-1]["allocationWidthPoints"],
            "allocationHeightPoints": ticks[-1]["allocationHeightPoints"],
            "dimensionsExact": exact,
            "gapP50Milliseconds": 0.0,
            "gapP95Milliseconds": 0.0,
            "gapP99Milliseconds": 0.0,
            "phaseDriftP99Milliseconds": 0.0,
            "skippedSourceFrames": 0,
            "kind": "frozen-frame",
            "frozenFrameID": freeze,
            "pass": exact and len(presented) >= 1,
        }

    rows = ticks[-WARM_SAMPLES:]
    if len(rows) < MIN_SAMPLES:
        return {**base, "pass": False,
                "error": f"motion source produced fewer than {MIN_SAMPLES} warm samples"}
    actual_by_frame = {}
    for row in events:
        if row.get("event") == "presentation" \
                and row.get("actualPresentationMicroseconds", 0) > 0:
            actual_by_frame.setdefault(
                row["frameID"], row["actualPresentationMicroseconds"])
    presented = [
        (row["frameID"], actual_by_frame[row["frameID"]])
        for row in rows if row["frameID"] in actual_by_frame
    ]
    gaps = [
        (right[1] - left[1]) / 1000
        for left, right in zip(presented, presented[1:])
    ] or [UNMEASURED_MS]
    origin_id, origin_us = presented[0] if presented else (0, 0)
    drift = [
        abs(presentation - origin_us - (frame_id - origin_id) * PERIOD_US) / 1000
        for frame_id, presentation in presented
    ] or [UNMEASURED_MS]
    exact = dimensions_exact(rows, width, height, scale)
    result = {
        **base,
        "samples": len(rows),
        "actualPresentations": len(presented),
        "allocationWidthPoints": rows[-1]["allocationWidthPoints"],
        "allocationHeightPoints": rows[-1]["allocationHeightPoints"],
        "dimensionsExact": exact,
        "gapP50Milliseconds": percentile(gaps, 50),
        "gapP95Milliseconds": percentile(gaps, 95),
        "gapP99Milliseconds": percentile(gaps, 99),
        "phaseDriftP99Milliseconds": percentile(drift, 99),
        "skippedSourceFrames": sum(row["skippedSourceFrames"] for row in rows),
    }
    result["pass"] = (
        exact
        and len(presented) >= MIN_SAMPLES
        and result["skippedSourceFrames"] == 0
        and result["gapP99Milliseconds"] <= MAX_GAP_P99_MS
        and result["phaseDriftP99Milliseconds"] <= MAX_PHASE_DRIFT_P99_MS
    )
    return result


def main(argv):
    if len(argv) not in (5, 6):
        print(__doc__, file=sys.stderr)
        return 2
    source, destination, width, height, scale = argv[:5]
    freeze = int(argv[5]) if len(argv) == 6 and argv[5] else None
    try:
        events = [json.loads(line) for line in Path(source).read_text().splitlines()]
        result = judge(events, int(width), int(height), float(scale), freeze)
    except (OSError, ValueError, KeyError) as error:
        result = {"pass": False, "error": f"unreadable motion source log: {error}"}
    Path(destination).write_text(json.dumps(result, separators=(",", ":")) + "\n")
    print(json.dumps(result, sort_keys=True))
    return 0 if result["pass"] else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

#!/usr/bin/env python3
"""Analyze Lyte.app benchmark JSONL and emit one machine-readable verdict."""

import argparse
import json
import math
import sys
from pathlib import Path


def percentile(values, percent):
    if not values:
        return None
    ordered = sorted(values)
    return ordered[max(0, math.ceil(percent / 100 * len(ordered)) - 1)]


def audio_interval_analysis(samples, warmup_seconds=3.0):
    keys = (
        "packetsPlayed",
        "plcInvocations",
        "latePacketsDropped",
        "recenterEvents",
        "packetsDroppedInRecenter",
        "underrunFrames",
        "declickProtectedUnderrunFrames",
        "decodeFailures",
        "routeChangeFailures",
    )
    previous = {key: 0 for key in keys}
    previous_time = 0.0
    intervals = []
    totals = {
        phase: {key: 0 for key in keys} for phase in ("warmup", "steadyState")
    }
    for sample_record in samples:
        audio = sample_record["audio"]
        end = float(sample_record["elapsedSeconds"])
        phase = "warmup" if end <= warmup_seconds else "steadyState"
        current = {
            key: audio.get(
                key,
                audio.get("underrunFrames", 0)
                if key == "declickProtectedUnderrunFrames"
                else 0,
            )
            for key in keys
        }
        delta = {
            key: max(0, current[key] - previous[key]) for key in keys
        }
        intervals.append(
            {
                "startSeconds": previous_time,
                "endSeconds": end,
                "phase": phase,
                "targetPackets": audio.get("targetPackets", 0),
                "ringDepthFrames": audio.get("ringDepthFrames", 0),
                "interArrivalStdDevMicroseconds":
                    audio.get("interArrivalStdDevMicroseconds", 0),
                **delta,
            }
        )
        for key in keys:
            totals[phase][key] += delta[key]
            previous[key] = current[key]
        previous_time = end
    steady_events = [
        interval for interval in intervals
        if interval["phase"] == "steadyState"
        and (
            interval["plcInvocations"]
            or interval["latePacketsDropped"]
            or interval["underrunFrames"]
        )
    ]
    steady_state_mitigated = all(
        interval["targetPackets"] >= 8
        and (
            interval["targetPackets"] >= 20
            or interval["interArrivalStdDevMicroseconds"] >= 3_000
            or (
                interval["plcInvocations"] == 0
                and interval["latePacketsDropped"] == 0
            )
        )
        and interval["plcInvocations"] <= 20
        and interval["underrunFrames"] <= 4_800
        and interval["declickProtectedUnderrunFrames"]
            == interval["underrunFrames"]
        for interval in steady_events
    )
    return {
        "warmupSeconds": warmup_seconds,
        "activeIntervals": [
            interval for interval in intervals
            if interval["plcInvocations"]
            or interval["latePacketsDropped"]
            or interval["underrunFrames"]
            or interval["recenterEvents"]
            or interval["packetsDroppedInRecenter"]
        ],
        "steadyStatePathTailMitigated": steady_state_mitigated,
        **totals,
    }


def analyze(path):
    records = [json.loads(line) for line in Path(path).read_text().splitlines()]
    samples = [record for record in records if record.get("type") == "sample"]
    ends = [record for record in records if record.get("type") == "end"]
    if not samples or not ends:
        raise ValueError("missing sample or end record (run did not finish cleanly)")
    latest, end = samples[-1], ends[-1]
    frames = {}
    for sample in samples:
        for frame in sample.get("frames", []):
            frames[frame["ordinal"]] = frame
    observations = list(frames.values())
    workload = latest["workload"]
    flight = latest["flight"]
    renderer = flight.get("rendererMetrics") or {}
    apple_drops = renderer.get("droppedFrames", 0)
    retained = sum(
        frame["provenance"] == "retainedRefinement" for frame in observations
    )
    fresh = len(observations) - retained
    bounded_debt_recovery = (
        flight["rendererFailures"] == 0
        and latest["video"]["sampleFailures"] == 0
        and flight["rendererRecoveries"] <= 1
        and flight["rendererDrops"] <= 4
        and latest["video"]["idrRequests"] <= 1
    )
    app_bad = (
        flight["rendererFailures"]
        + latest["video"]["sampleFailures"]
        + (0 if bounded_debt_recovery else flight["rendererDrops"])
        + (0 if bounded_debt_recovery else flight["rendererRecoveries"])
    )
    corrupted = renderer.get("corruptedFrames", 0)
    presentations = [
        frame["scheduledPresentationMicroseconds"]
        for frame in observations
        if frame.get("scheduledPresentationMicroseconds") is not None
        and not frame.get("rendererDropped", False)
    ]
    presentation_regressions = sum(
        right < left for left, right in zip(presentations, presentations[1:])
    )
    accumulated_delay = renderer.get("accumulatedDelayMilliseconds", 0)
    if apple_drops == 0:
        drop_class = "none"
    elif (
        app_bad == 0
        and corrupted == 0
        and presentation_regressions == 0
        and apple_drops <= retained
    ):
        drop_class = "compatible_with_retained_display_coalescing"
    elif (
        app_bad == 0
        and corrupted == 0
        and presentation_regressions == 0
        and accumulated_delay < 8
    ):
        drop_class = "post_decode_display_coalescing_dependency_preserved"
    elif bounded_debt_recovery and corrupted == 0 and presentation_regressions == 0:
        drop_class = "bounded_fresh_debt_recovery_dependency_preserved"
    elif presentation_regressions:
        drop_class = "non_monotonic_pts_display_drops"
    else:
        drop_class = "unresolved_renderer_drops"

    elapsed = max(float(end["elapsedSeconds"]), 0.001)
    video = latest["video"]
    audio = latest["audio"]
    audio_intervals = audio_interval_analysis(samples)
    warmup_audio = audio_intervals["warmup"]
    steady_audio = audio_intervals["steadyState"]
    idr_per_minute = video["idrRequests"] * 60 / elapsed
    plc_ratio = audio["plcInvocations"] / max(1, audio["packetsPlayed"])
    late_ratio = audio["latePacketsDropped"] / max(
        1, audio["packetsPlayed"] + audio["latePacketsDropped"]
    )
    hard_failures = []
    if not end.get("everStreaming"):
        hard_failures.append("no_connection")
    if flight["frames"] == 0 or video["framesDecoded"] == 0:
        hard_failures.append("no_frames")
    if flight["rendererFailures"] or video["sampleFailures"]:
        hard_failures.append("renderer_failure")
    if (flight["rendererDrops"] or flight["rendererRecoveries"]) \
            and not bounded_debt_recovery:
        hard_failures.append("app_handoff_drop_or_recovery")
    if flight["rendererNotReady"]:
        hard_failures.append("renderer_backpressure")
    if corrupted:
        hard_failures.append("renderer_corruption")
    if drop_class in (
        "non_monotonic_pts_display_drops",
        "unresolved_renderer_drops",
    ):
        hard_failures.append(drop_class)
    if video["idrRequests"] > 1 and idr_per_minute > 2:
        hard_failures.append("idr_recovery_storm")
    warmup_mitigated = (
        warmup_audio["plcInvocations"] <= 40
        and warmup_audio["underrunFrames"] <= 9_600
        and warmup_audio["declickProtectedUnderrunFrames"]
        == warmup_audio["underrunFrames"]
    )
    if audio["packetsUnrecoverable"]:
        hard_failures.append("audio_wire_loss")
    if not warmup_mitigated:
        hard_failures.append("audio_warmup_not_bounded_or_declicked")
    steady_has_continuity_event = (
        steady_audio["plcInvocations"]
        or steady_audio["latePacketsDropped"]
        or steady_audio["underrunFrames"]
    )
    steady_mitigated = audio_intervals["steadyStatePathTailMitigated"]
    if steady_has_continuity_event and not steady_mitigated:
        hard_failures.append("audio_steady_state_late_or_plc")
    if audio["plcPacketsFed"] != audio["plcInvocations"]:
        hard_failures.append("audio_plc_feed_mismatch")
    if audio["decodeFailures"] or audio["routeChangeFailures"]:
        hard_failures.append("audio_output_failure")

    metric_keys = (
        "queueWaitMilliseconds",
        "enqueueMilliseconds",
        "presentationLatenessMilliseconds",
        "readyGapMilliseconds",
        "transitStretchMilliseconds",
    )
    timing = {}
    for key in metric_keys:
        values = [
            frame[key] for frame in observations if frame.get(key) is not None
        ]
        stem = key.removesuffix("Milliseconds")
        timing[f"{stem}P50Milliseconds"] = percentile(values, 50)
        timing[f"{stem}P99Milliseconds"] = percentile(values, 99)

    result = {
        "type": "lyte_app_benchmark_verdict",
        "schemaVersion": 1,
        "runID": latest["runID"],
        "workload": workload,
        "elapsedSeconds": elapsed,
        "verdict": "PASS" if not hard_failures else "FAIL",
        "failures": hard_failures,
        "frames": {
            "decoded": video["framesDecoded"],
            "observed": len(observations),
            "freshCapture": fresh,
            "retainedRefinement": retained,
        },
        "timing": timing,
        "renderer": {
            "appHandoffDrops": flight["rendererDrops"],
            "appBackpressure": flight["rendererNotReady"],
            "appFailures": flight["rendererFailures"],
            "appRecoveries": flight["rendererRecoveries"],
            "appleTotalFrames": renderer.get("totalFrames", 0),
            "appleDisplayDrops": apple_drops,
            "appleCorruptedFrames": corrupted,
            "appleAccumulatedDelayMilliseconds": accumulated_delay,
            "presentationTimestampRegressions": presentation_regressions,
            "appleDropClassification": drop_class,
        },
        "recovery": {
            "idrRequests": video["idrRequests"],
            "idrRetries": video["idrRetries"],
            "idrRequestsPerMinute": idr_per_minute,
        },
        "audio": {
            **audio,
            "plcRatio": plc_ratio,
            "latePacketRatio": late_ratio,
            "continuityClassification": (
                "steady_state_clean_with_bounded_warmup"
                if warmup_mitigated
                and not steady_audio["plcInvocations"]
                and not steady_audio["latePacketsDropped"]
                and not steady_audio["underrunFrames"]
                else (
                    "bounded_path_tail_concealed"
                    if warmup_mitigated and steady_mitigated
                    else "continuity_failure"
                )
            ),
            "intervalAnalysis": audio_intervals,
        },
    }
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("jsonl")
    parser.add_argument("--pretty", action="store_true")
    args = parser.parse_args()
    try:
        result = analyze(args.jsonl)
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as error:
        print(json.dumps({"type": "lyte_app_benchmark_error", "error": str(error)}))
        return 2
    print(json.dumps(result, indent=2 if args.pretty else None, sort_keys=True))
    return 0 if result["verdict"] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())

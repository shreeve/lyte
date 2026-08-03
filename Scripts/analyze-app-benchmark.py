#!/usr/bin/env python3
"""Analyze Lyte.app benchmark JSONL and emit one machine-readable verdict."""

import argparse
import json
import math
import sys
from pathlib import Path


# Commissioning floors for the native-seat witness, measured against
# the motion-definition pattern (2026-08-02, quality-static leg on the
# rig: min-channel 31.2 dB, G 40.6 dB, luma SSIM 0.9991). The pattern
# is chroma-adversarial by design — thin saturated lines pin R/B near
# 31 dB at 4:2:0 regardless of encoder health — so the min-channel
# floors sit below the measured baseline to catch regressions
# (colorimetry swaps, encoder faults) rather than assert headroom the
# chroma format cannot give. Raising them is the direct-leg quality
# refinement's job.
QUALITY_ACTIVE_MIN_DB = 28.0
QUALITY_CONVERGED_MIN_DB = 30.0
QUALITY_CONVERGED_MIN_SSIM = 0.995


def percentile(values, percent):
    if not values:
        return None
    ordered = sorted(values)
    return ordered[max(0, math.ceil(percent / 100 * len(ordered)) - 1)]


def motion_cadence_analysis(source, observations):
    fresh = [
        frame for frame in observations
        if frame.get("provenance") == "freshCapture"
    ]
    capture_gaps = [
        frame["sourceGapMilliseconds"] for frame in fresh
        if frame.get("sourceGapMilliseconds") is not None
    ]
    transit = [
        frame["transitStretchMilliseconds"] for frame in fresh
        if frame.get("transitStretchMilliseconds") is not None
    ]
    presentation_lateness = [
        abs(frame["presentationLatenessMilliseconds"]) for frame in fresh
        if frame.get("presentationLatenessMilliseconds") is not None
    ]
    # The source's warm-up catch-up sprint presents late by
    # construction; judge presentation lateness on steady state (same
    # 3 s split as the audio and source gates), falling back to the
    # whole run when the timeline is too short to split.
    timeline_start = next(
        (frame["scheduledPresentationMicroseconds"] for frame in fresh
         if frame.get("scheduledPresentationMicroseconds") is not None),
        None,
    )
    steady_lateness = [
        abs(frame["presentationLatenessMilliseconds"]) for frame in fresh
        if frame.get("presentationLatenessMilliseconds") is not None
        and frame.get("scheduledPresentationMicroseconds") is not None
        and timeline_start is not None
        and frame["scheduledPresentationMicroseconds"] - timeline_start
        > 3.0 * 1_000_000
    ]
    gated_lateness = steady_lateness or presentation_lateness
    presentations = [
        frame["scheduledPresentationMicroseconds"] for frame in fresh
        if frame.get("scheduledPresentationMicroseconds") is not None
    ]
    presentation_gaps = [
        (right - left) / 1_000
        for left, right in zip(presentations, presentations[1:])
    ]
    queue_wait = [
        frame["queueWaitMilliseconds"] for frame in fresh
        if frame.get("queueWaitMilliseconds") is not None
    ]
    first_boundary = "clean"
    failure = None
    if source is None:
        first_boundary = "source_evidence"
        failure = "motion_source_evidence_missing"
    elif (
        not source.get("pass", False)
        or not source.get("dimensionsExact", False)
        or source.get("skippedSourceFrames", 0) > 0
        or source.get("gapP99Milliseconds", math.inf) > 25
        or source.get("phaseDriftP99Milliseconds", math.inf) > 8
    ):
        first_boundary = "source_compositor"
        failure = "motion_source_cadence_failed"
    elif percentile(capture_gaps, 99) is None \
            or percentile(capture_gaps, 99) > 25:
        first_boundary = "pipewire_capture"
        failure = "motion_capture_cadence_failed"
    elif (percentile(transit, 99) or 0) > 8:
        # Endpoint captures localize the recurring live tail after Host
        # interface capture and before client packet delivery. The flight
        # metric remains broader in synthetic/unit fixtures, so name the
        # observed boundary without falsely assigning it to the encoder.
        first_boundary = "host_to_client_delivery"
        failure = "motion_transport_burst"
    elif (
        (percentile(queue_wait, 99) or 0) > 8
        or (percentile(gated_lateness, 99) or 0) > 8
        or (percentile(presentation_gaps, 99) or 0) > 25
    ):
        first_boundary = "client_presentation"
        failure = "motion_client_presentation_jitter"
    return {
        "source": source,
        "captureGapP50Milliseconds": percentile(capture_gaps, 50),
        "captureGapP95Milliseconds": percentile(capture_gaps, 95),
        "captureGapP99Milliseconds": percentile(capture_gaps, 99),
        "transportStretchP50Milliseconds": percentile(transit, 50),
        "transportStretchP95Milliseconds": percentile(transit, 95),
        "transportStretchP99Milliseconds": percentile(transit, 99),
        "presentationGapP50Milliseconds": percentile(presentation_gaps, 50),
        "presentationGapP95Milliseconds": percentile(presentation_gaps, 95),
        "presentationGapP99Milliseconds": percentile(presentation_gaps, 99),
        "presentationLatenessP99Milliseconds":
            percentile(presentation_lateness, 99),
        "steadyStatePresentationLatenessP99Milliseconds":
            percentile(steady_lateness, 99) if steady_lateness else None,
        "firstJaggedBoundary": first_boundary,
        "failure": failure,
    }


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
                "hostAnnouncedQuiet":
                    bool(audio.get("hostAnnouncedQuiet", False)),
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
    def announced_quiet_stillness(interval):
        # The host declared quiet (0x25): silence is intentional.
        # Underruns must all ride the declick path; PLC stays bounded
        # to the one-time ring drain at the gate boundary (≤ 200 ms of
        # 5 ms packets); and a few boundary stragglers — near-silent
        # tail packets arriving after the ring re-based — may drop
        # late (≤ 40 ms). Sustained late drops still fail.
        return (
            interval["hostAnnouncedQuiet"]
            and interval["latePacketsDropped"] <= 8
            and interval["plcInvocations"] <= 40
            and interval["declickProtectedUnderrunFrames"]
                == interval["underrunFrames"]
        )

    steady_state_mitigated = all(
        announced_quiet_stillness(interval)
        or (
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
        )
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
        "steadyContinuityEvents": len(steady_events),
        "announcedQuietSteadyEvents": sum(
            1 for interval in steady_events
            if announced_quiet_stillness(interval)
        ),
        **totals,
    }


def quality_analysis(samples, elapsed):
    observations = [
        sample["quality"] for sample in samples
        if sample.get("quality") is not None
    ]
    valid = [
        item for item in observations
        if item.get("error") is None
        and item.get("psnrMinDB") is not None
        and item.get("lumaSSIM") is not None
    ]
    warmup = [item for item in valid if float(item["elapsedSeconds"]) <= 3.0]
    steady = [item for item in valid if float(item["elapsedSeconds"]) > 3.0]
    expected_steady = [
        sample for sample in samples
        if float(sample["elapsedSeconds"]) > 3.0
    ]
    dimensions_exact = bool(valid) and all(
        item.get("decodedWidth") == item.get("sourceWidth")
        and item.get("decodedHeight") == item.get("sourceHeight")
        for item in valid
    )
    stale_intervals = 0
    decoded_monotonic = True
    decoded_advanced = False
    decoded_progress_fps = 0.0
    if len(valid) >= 2:
        decoded_monotonic = all(
            right["decodedFrames"] >= left["decodedFrames"]
            for left, right in zip(valid, valid[1:])
        )
        decoded_advanced = (
            valid[-1]["decodedFrames"] > valid[0]["decodedFrames"]
            or valid[0]["decodedFrames"] > 1
        )
    if len(steady) >= 2:
        stale_intervals = sum(
            right["decodedFrames"] <= left["decodedFrames"]
            for left, right in zip(steady, steady[1:])
        )
        span = float(steady[-1]["elapsedSeconds"]) \
            - float(steady[0]["elapsedSeconds"])
        if span > 0:
            decoded_progress_fps = (
                steady[-1]["decodedFrames"] - steady[0]["decodedFrames"]
            ) / span
    psnrs = [float(item["psnrMinDB"]) for item in valid]
    ssims = [float(item["lumaSSIM"]) for item in valid]
    latest = observations[-1] if observations else {}
    return {
        "thresholds": {
            "activeMinRGBPSNRDB": QUALITY_ACTIVE_MIN_DB,
            "convergedMinRGBPSNRDB": QUALITY_CONVERGED_MIN_DB,
            "convergedMinLumaSSIM": QUALITY_CONVERGED_MIN_SSIM,
        },
        "observations": len(observations),
        "validObservations": len(valid),
        "steadyObservations": len(steady),
        "expectedSteadyObservations": len(expected_steady),
        "readbackErrors": [
            {
                "elapsedSeconds": item["elapsedSeconds"],
                "error": item["error"],
            }
            for item in observations if item.get("error") is not None
        ],
        "timeSeries": [
            {
                key: item.get(key) for key in (
                    "elapsedSeconds",
                    "decodedFrames",
                    "decodedWidth",
                    "decodedHeight",
                    "psnrRDB",
                    "psnrGDB",
                    "psnrBDB",
                    "psnrMinDB",
                    "lumaSSIM",
                    "syntheticFrameID",
                    "phaseMatched",
                    "error",
                )
            }
            for item in observations
        ],
        "dimensionsExact": dimensions_exact,
        "cadencePolicy": "static_idle_floor_retention",
        "decodedProgressFPS": decoded_progress_fps,
        "decodedFramesMonotonic": decoded_monotonic,
        "decodedFramesAdvancedDuringRun": decoded_advanced,
        "staleReadbackIntervals": stale_intervals,
        "minRGBPSNRDB": min(psnrs) if psnrs else None,
        "p50RGBPSNRDB": percentile(psnrs, 50),
        "minLumaSSIM": min(ssims) if ssims else None,
        "p50LumaSSIM": percentile(ssims, 50),
        # Vacuously true when the probe has no clean warm-up frame: probe
        # errors surface through the phase gate and a missing steady
        # window through the readback-gap gate, so an empty warm-up is
        # not itself a failure.
        "warmupPass": all(
            item["psnrMinDB"] >= QUALITY_ACTIVE_MIN_DB for item in warmup
        ),
        "steadyPass": bool(steady) and all(
            item["psnrMinDB"] >= QUALITY_CONVERGED_MIN_DB
            and item["lumaSSIM"] >= QUALITY_CONVERGED_MIN_SSIM
            for item in steady
        ),
        "geometry": {
            key: latest.get(key) for key in (
                "sourceWidth",
                "sourceHeight",
                "decodedWidth",
                "decodedHeight",
                "viewportWidthPoints",
                "viewportHeightPoints",
                "viewportWidthPixels",
                "viewportHeightPixels",
                "backingScaleFactor",
                "fittedVideoWidthPoints",
                "fittedVideoHeightPoints",
                "displayScaleX",
                "displayScaleY",
            )
        },
        "readbackMetadata": {
            key: latest.get(key) for key in (
                "readbackPixelFormat",
                "readbackBytesPerRow",
                "readbackYCbCrMatrix",
                "readbackColorPrimaries",
                "readbackTransferFunction",
            )
        },
        "referenceName": latest.get("referenceName"),
        "elapsedSeconds": elapsed,
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
    quality = quality_analysis(samples, elapsed)
    motion = motion_cadence_analysis(latest.get("motionSource"), observations)
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
    # The native-seat quality witness: both witness legs decode the
    # motion presenter's marker, regenerate the authored frame from the
    # client twin (SyntheticMotionReference, pinned byte-exact to the
    # presenter by shared SHA fixtures), and PSNR/SSIM the GPU readback
    # of the displayed buffer against it.
    if workload in ("motion", "quality-static"):
        if quality["referenceName"] != "motion-definition-v1":
            hard_failures.append("quality_reference_not_controlled_corpus")
        if quality["validObservations"] == 0:
            hard_failures.append("quality_no_native_readback")
        if quality["steadyObservations"] != quality["expectedSteadyObservations"]:
            hard_failures.append("quality_readback_gap")
        if not quality["dimensionsExact"]:
            hard_failures.append("quality_dimension_or_scaling_mismatch")
        if any(
            item.get("error") is not None
            or item.get("phaseMatched") is not True
            or item.get("syntheticFrameID") is None
            for item in quality["timeSeries"]
        ):
            hard_failures.append("quality_phase_ambiguous")
        if not quality["warmupPass"]:
            hard_failures.append("quality_active_psnr_below_floor")
        if not quality["steadyPass"]:
            hard_failures.append("quality_converged_gate_failed")
    if workload == "quality-static":
        # The frozen frame still decodes at keepalive cadence; a parked
        # readback that stops advancing is a retention failure, not quiet.
        if not quality["decodedFramesMonotonic"] \
                or not quality["decodedFramesAdvancedDuringRun"]:
            hard_failures.append("quality_static_retention_failed")
    if workload == "motion":
        if motion["failure"] is not None:
            hard_failures.append(motion["failure"])

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
        timing[f"{stem}P95Milliseconds"] = percentile(values, 95)
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
            "recoveryCauses": flight.get("recoveryCauses", {}),
            "recoveryLifecycle": flight.get("recoveryLifecycle", []),
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
                    "announced_quiet_stillness"
                    if warmup_mitigated
                    and steady_mitigated
                    and audio_intervals["announcedQuietSteadyEvents"]
                        == audio_intervals["steadyContinuityEvents"]
                    else (
                        "bounded_path_tail_concealed"
                        if warmup_mitigated and steady_mitigated
                        else "continuity_failure"
                    )
                )
            ),
            "intervalAnalysis": audio_intervals,
        },
        "quality": quality,
        "motion": motion,
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

#!/usr/bin/env python3
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


SPEC = importlib.util.spec_from_file_location(
    "analyzer", Path(__file__).with_name("analyze-app-benchmark.py")
)
ANALYZER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ANALYZER)

PRESENTER_SPEC = importlib.util.spec_from_file_location(
    "presenter", Path(__file__).with_name("motion-presenter.py")
)
PRESENTER = importlib.util.module_from_spec(PRESENTER_SPEC)
PRESENTER_SPEC.loader.exec_module(PRESENTER)


def sample(workload, apple_drops, provenances):
    frames = []
    for ordinal, provenance in enumerate(provenances, 1):
        frames.append(
            {
                "ordinal": ordinal,
                "provenance": provenance,
                "queueWaitMilliseconds": float(ordinal),
                "enqueueMilliseconds": 0.1,
                "presentationLatenessMilliseconds": 0.0,
                "scheduledPresentationMicroseconds": ordinal * 16_667,
                "sourceGapMilliseconds": 16.667,
                "readyGapMilliseconds": 16.0,
                "transitStretchMilliseconds": 0.2,
            }
        )
    fixture = {
        "type": "sample",
        "runID": "test",
        "workload": workload,
        "elapsedSeconds": 30.0,
        "phase": "streaming",
        "frames": frames,
        "flight": {
            "frames": len(frames),
            "rendererDrops": 0,
            "rendererFailures": 0,
            "rendererRecoveries": 0,
            "rendererNotReady": 0,
            "rendererMetrics": {
                "totalFrames": len(frames),
                "droppedFrames": apple_drops,
                "corruptedFrames": 0,
                "accumulatedDelayMilliseconds": 0.25,
            },
        },
        "video": {
            "framesDecoded": len(frames),
            "sampleFailures": 0,
            "idrRequests": 0,
            "idrRetries": 0,
        },
        "audio": {
            "packetsPlayed": 1000,
            "plcInvocations": 0,
            "plcPacketsFed": 0,
            "latePacketsDropped": 0,
            "packetsUnrecoverable": 0,
            "underrunFrames": 0,
            "declickProtectedUnderrunFrames": 0,
            "decodeFailures": 0,
            "routeChangeFailures": 0,
        },
    }
    if workload == "motion":
        fixture["quality"] = quality_observation(30.0, len(frames) or 1)
        fixture["motionSource"] = {
            "samples": 180,
            "width": 2048,
            "height": 1280,
            "logicalScale": 4 / 3,
            "allocationWidthPoints": 1536,
            "allocationHeightPoints": 960,
            "dimensionsExact": True,
            "gapP50Milliseconds": 16.667,
            "gapP95Milliseconds": 16.8,
            "gapP99Milliseconds": 17.0,
            "phaseDriftP99Milliseconds": 0.5,
            "skippedSourceFrames": 0,
            "pass": True,
        }
    return fixture


def quality_observation(elapsed, decoded_frames, psnr=46.0, ssim=0.996):
    return {
        "elapsedSeconds": elapsed,
        "decodedFrames": decoded_frames,
        "referenceName": "motion-definition-v1",
        "sourceWidth": 1920,
        "sourceHeight": 1080,
        "decodedWidth": 1920,
        "decodedHeight": 1080,
        "psnrRDB": psnr + 1,
        "psnrGDB": psnr,
        "psnrBDB": psnr + 0.5,
        "psnrMinDB": psnr,
        "lumaSSIM": ssim,
        "syntheticFrameID": decoded_frames,
        "phaseMatched": True,
        "viewportWidthPoints": 1280,
        "viewportHeightPoints": 720,
        "viewportWidthPixels": 2560,
        "viewportHeightPixels": 1440,
        "backingScaleFactor": 2,
        "fittedVideoWidthPoints": 1280,
        "fittedVideoHeightPoints": 720,
        "displayScaleX": 2 / 3,
        "displayScaleY": 2 / 3,
        "error": None,
    }


def quality_sample(
    elapsed, decoded_frames, psnr=46.0, ssim=0.996, chroma=None
):
    fixture = sample("quality-static", 0, ["freshCapture"])
    fixture["elapsedSeconds"] = elapsed
    fixture["video"]["framesDecoded"] = decoded_frames
    fixture["quality"] = quality_observation(
        elapsed, decoded_frames, psnr, ssim)
    if chroma is not None:
        fixture["streamChroma"] = chroma
    return fixture


class AnalyzerTests(unittest.TestCase):
    def analyze(self, one_sample, ever_streaming=True, samples=None):
        end = {
            "type": "end",
            "elapsedSeconds": 30.0,
            "everStreaming": ever_streaming,
        }
        with tempfile.NamedTemporaryFile(mode="w", delete=False) as stream:
            for record in samples or [one_sample]:
                stream.write(json.dumps(record) + "\n")
            stream.write(json.dumps(end) + "\n")
            path = stream.name
        try:
            return ANALYZER.analyze(path)
        finally:
            Path(path).unlink()

    def test_retained_drop_is_classified_separately_and_passes(self):
        result = self.analyze(
            sample(
                "static",
                2,
                ["freshCapture", "retainedRefinement", "retainedRefinement"],
            )
        )
        self.assertEqual(result["verdict"], "PASS")
        self.assertEqual(
            result["renderer"]["appleDropClassification"],
            "compatible_with_retained_display_coalescing",
        )
        self.assertEqual(result["timing"]["queueWaitP50Milliseconds"], 2.0)
        self.assertEqual(result["timing"]["queueWaitP99Milliseconds"], 3.0)

    def test_clean_monotonic_motion_drops_are_post_decode_coalescing(self):
        result = self.analyze(
            sample("motion", 2, ["freshCapture", "freshCapture"])
        )
        self.assertEqual(result["verdict"], "PASS")
        self.assertEqual(
            result["renderer"]["appleDropClassification"],
            "post_decode_display_coalescing_dependency_preserved",
        )
        self.assertEqual(result["motion"]["firstJaggedBoundary"], "clean")

    def test_motion_source_jitter_is_first_boundary(self):
        fixture = sample("motion", 0, ["freshCapture"] * 4)
        fixture["motionSource"]["gapP99Milliseconds"] = 29.0
        fixture["motionSource"]["pass"] = False
        result = self.analyze(fixture)
        self.assertIn("motion_source_cadence_failed", result["failures"])
        self.assertEqual(
            result["motion"]["firstJaggedBoundary"], "source_compositor")

    def test_motion_capture_jitter_is_first_lyte_boundary(self):
        fixture = sample("motion", 0, ["freshCapture"] * 4)
        fixture["frames"][-1]["sourceGapMilliseconds"] = 30.0
        result = self.analyze(fixture)
        self.assertIn("motion_capture_cadence_failed", result["failures"])
        self.assertEqual(
            result["motion"]["firstJaggedBoundary"], "pipewire_capture")

    def test_motion_transport_burst_is_first_lyte_boundary(self):
        fixture = sample("motion", 0, ["freshCapture"] * 4)
        fixture["frames"][-1]["transitStretchMilliseconds"] = 12.0
        result = self.analyze(fixture)
        self.assertIn("motion_transport_burst", result["failures"])
        self.assertEqual(
            result["motion"]["firstJaggedBoundary"],
            "host_to_client_delivery")

    def test_motion_client_presentation_jitter_is_first_boundary(self):
        fixture = sample("motion", 0, ["freshCapture"] * 4)
        fixture["frames"][-1]["presentationLatenessMilliseconds"] = 12.0
        result = self.analyze(fixture)
        self.assertIn(
            "motion_client_presentation_jitter", result["failures"])
        self.assertEqual(
            result["motion"]["firstJaggedBoundary"], "client_presentation")

    def test_pts_regression_with_apple_drops_fails(self):
        fixture = sample("motion", 1, ["freshCapture", "freshCapture"])
        fixture["frames"][1]["scheduledPresentationMicroseconds"] = 1
        result = self.analyze(fixture)
        self.assertEqual(result["verdict"], "FAIL")
        self.assertIn("non_monotonic_pts_display_drops", result["failures"])

    def test_no_connection_and_audio_underrun_fail_loudly(self):
        fixture = sample("static", 0, ["freshCapture"])
        fixture["audio"]["underrunFrames"] = 48
        fixture["audio"]["declickProtectedUnderrunFrames"] = 48
        result = self.analyze(fixture, ever_streaming=False)
        self.assertIn("no_connection", result["failures"])
        self.assertIn("audio_steady_state_late_or_plc", result["failures"])

    def test_bounded_declicked_warmup_passes_when_steady_state_is_clean(self):
        warmup = sample("static", 0, ["freshCapture"])
        warmup["elapsedSeconds"] = 2.0
        warmup["audio"]["packetsPlayed"] = 300
        warmup["audio"]["plcInvocations"] = 4
        warmup["audio"]["plcPacketsFed"] = 4
        warmup["audio"]["latePacketsDropped"] = 4
        warmup["audio"]["underrunFrames"] = 960
        warmup["audio"]["declickProtectedUnderrunFrames"] = 960
        steady = json.loads(json.dumps(warmup))
        steady["elapsedSeconds"] = 30.0
        steady["audio"]["packetsPlayed"] = 5_000
        result = self.analyze(steady, samples=[warmup, steady])
        self.assertEqual(result["verdict"], "PASS")
        self.assertEqual(
            result["audio"]["continuityClassification"],
            "steady_state_clean_with_bounded_warmup",
        )

    def test_steady_state_late_plc_fails_without_relaxing_slo(self):
        warmup = sample("motion", 0, ["freshCapture"])
        warmup["elapsedSeconds"] = 2.0
        warmup["quality"]["elapsedSeconds"] = 2.0
        steady = json.loads(json.dumps(warmup))
        steady["elapsedSeconds"] = 10.0
        steady["quality"]["elapsedSeconds"] = 10.0
        steady["audio"]["plcInvocations"] = 1
        steady["audio"]["plcPacketsFed"] = 1
        steady["audio"]["latePacketsDropped"] = 1
        result = self.analyze(steady, samples=[warmup, steady])
        self.assertIn("audio_steady_state_late_or_plc", result["failures"])

    def test_bounded_steady_blackout_at_ceiling_is_mitigated(self):
        warmup = sample("motion", 0, ["freshCapture"])
        warmup["elapsedSeconds"] = 2.0
        warmup["quality"]["elapsedSeconds"] = 2.0
        warmup["audio"]["targetPackets"] = 20
        steady = json.loads(json.dumps(warmup))
        steady["elapsedSeconds"] = 10.0
        steady["quality"]["elapsedSeconds"] = 10.0
        steady["audio"]["targetPackets"] = 20
        steady["audio"]["interArrivalStdDevMicroseconds"] = 4_000
        steady["audio"]["plcInvocations"] = 3
        steady["audio"]["plcPacketsFed"] = 3
        steady["audio"]["latePacketsDropped"] = 3
        steady["audio"]["underrunFrames"] = 960
        steady["audio"]["declickProtectedUnderrunFrames"] = 960
        result = self.analyze(steady, samples=[warmup, steady])
        self.assertEqual(result["verdict"], "PASS")
        self.assertEqual(
            result["audio"]["continuityClassification"],
            "bounded_path_tail_concealed",
        )

    def test_idle_floor_static_quality_scores_native_pixels_over_time(self):
        fixtures = [
            quality_sample(1.0, 11, psnr=41.0, ssim=0.990),
            quality_sample(2.0, 25, psnr=44.0, ssim=0.994),
            quality_sample(4.0, 29),
            quality_sample(5.0, 29),
            quality_sample(6.0, 29),
        ]
        result = self.analyze(fixtures[-1], samples=fixtures)
        self.assertEqual(result["verdict"], "PASS")
        self.assertEqual(result["quality"]["steadyObservations"], 3)
        self.assertEqual(result["quality"]["decodedProgressFPS"], 0)
        self.assertEqual(result["quality"]["staleReadbackIntervals"], 2)
        self.assertTrue(result["quality"]["decodedFramesAdvancedDuringRun"])
        self.assertEqual(
            result["quality"]["cadencePolicy"],
            "static_idle_floor_retention",
        )
        self.assertTrue(result["quality"]["dimensionsExact"])
        self.assertEqual(result["quality"]["geometry"]["backingScaleFactor"], 2)

    def test_static_quality_can_converge_before_first_probe(self):
        fixtures = [
            quality_sample(1.0, 50),
            quality_sample(2.0, 50),
            quality_sample(4.0, 50),
            quality_sample(5.0, 50),
        ]
        result = self.analyze(fixtures[-1], samples=fixtures)
        self.assertEqual(result["verdict"], "PASS")
        self.assertTrue(result["quality"]["decodedFramesAdvancedDuringRun"])
        self.assertNotIn("quality_static_retention_failed", result["failures"])

    def test_best_tier_floors_hold_the_444_standard(self):
        # 52 dB passes 4:2:0's converged floor (30) by 22 dB, but a
        # Best-tier stream is graded on the 4:4:4 bar (50/0.9995) —
        # the commissioned 2026-08-03 baseline is 56.8–57.6 dB, so a
        # slide to 48 dB is a REGRESSION the old floor would bless.
        passing = [
            quality_sample(t, 29, psnr=52.0, ssim=0.99990, chroma="4:4:4")
            for t in (1.0, 2.0, 4.0, 5.0, 6.0)
        ]
        result = self.analyze(passing[-1], samples=passing)
        self.assertEqual(result["verdict"], "PASS")
        self.assertEqual(result["quality"]["streamChroma"], "4:4:4")
        self.assertEqual(
            result["quality"]["thresholds"]["convergedMinRGBPSNRDB"], 50.0)

        sliding = [
            quality_sample(t, 29, psnr=48.0, ssim=0.99990, chroma="4:4:4")
            for t in (1.0, 2.0, 4.0, 5.0, 6.0)
        ]
        result = self.analyze(sliding[-1], samples=sliding)
        self.assertEqual(result["verdict"], "FAIL")
        self.assertIn("quality_converged_gate_failed", result["failures"])

    def test_420_streams_keep_the_legacy_floors(self):
        # The same 31 dB that is honest 4:2:0 health must not be
        # graded on the 4:4:4 bar; absent streamChroma (a pre-tier
        # recording) grades 4:2:0 too.
        for chroma in ("4:2:0", None):
            fixtures = [
                quality_sample(t, 29, psnr=31.2, ssim=0.9991, chroma=chroma)
                for t in (1.0, 2.0, 4.0, 5.0, 6.0)
            ]
            result = self.analyze(fixtures[-1], samples=fixtures)
            self.assertEqual(result["verdict"], "PASS")
            self.assertEqual(
                result["quality"]["thresholds"]["convergedMinRGBPSNRDB"],
                30.0)

    def test_cadence_clean_but_blurry_quality_fails(self):
        fixtures = [
            quality_sample(1.0, 60, psnr=29.0),
            quality_sample(2.0, 120, psnr=29.4),
            quality_sample(4.0, 240, psnr=29.9),
            quality_sample(5.0, 300, psnr=29.9),
        ]
        result = self.analyze(fixtures[-1], samples=fixtures)
        self.assertEqual(result["verdict"], "FAIL")
        self.assertIn("quality_converged_gate_failed", result["failures"])
        self.assertNotIn("quality_static_retention_failed", result["failures"])

    def test_quality_rejects_scaling_and_readback_gaps(self):
        fixtures = [
            quality_sample(1.0, 60, psnr=41.0),
            quality_sample(2.0, 120, psnr=42.0),
            quality_sample(4.0, 240),
            quality_sample(5.0, 300),
        ]
        fixtures[2]["quality"]["decodedWidth"] = 1280
        fixtures[2]["quality"]["decodedHeight"] = 720
        fixtures[3]["quality"]["error"] = "no_displayed_pixel_buffer"
        fixtures[3]["quality"]["psnrMinDB"] = None
        fixtures[3]["quality"]["lumaSSIM"] = None
        result = self.analyze(fixtures[-1], samples=fixtures)
        self.assertIn(
            "quality_dimension_or_scaling_mismatch", result["failures"]
        )
        self.assertIn("quality_readback_gap", result["failures"])

    def test_motion_leg_without_readback_fails_the_witness(self):
        fixture = sample("motion", 0, ["freshCapture"] * 4)
        del fixture["quality"]
        result = self.analyze(fixture)
        self.assertEqual(result["verdict"], "FAIL")
        self.assertIn("quality_no_native_readback", result["failures"])

    def test_witness_rejects_a_foreign_reference(self):
        fixture = sample("motion", 0, ["freshCapture"] * 4)
        fixture["quality"]["referenceName"] = "text-100"
        result = self.analyze(fixture)
        self.assertIn(
            "quality_reference_not_controlled_corpus", result["failures"])

    def test_witness_rejects_an_ambiguous_phase(self):
        fixtures = [
            quality_sample(1.0, 60),
            quality_sample(2.0, 120),
            quality_sample(4.0, 240),
            quality_sample(5.0, 300),
        ]
        fixtures[2]["quality"]["phaseMatched"] = False
        result = self.analyze(fixtures[-1], samples=fixtures)
        self.assertIn("quality_phase_ambiguous", result["failures"])

    def test_clean_motion_witness_passes_end_to_end(self):
        fixture = sample("motion", 2, ["freshCapture", "freshCapture"])
        result = self.analyze(fixture)
        self.assertEqual(result["verdict"], "PASS")
        self.assertNotIn("quality_converged_gate_failed", result["failures"])

    def test_announced_quiet_stillness_is_not_a_blackout(self):
        warmup = quality_sample(2.0, 30)
        steady = quality_sample(10.0, 40)
        steady["audio"]["hostAnnouncedQuiet"] = True
        steady["audio"]["plcInvocations"] = 20
        steady["audio"]["plcPacketsFed"] = 20
        steady["audio"]["underrunFrames"] = 15_070
        steady["audio"]["declickProtectedUnderrunFrames"] = 15_070
        result = self.analyze(steady, samples=[warmup, steady])
        self.assertEqual(result["verdict"], "PASS")
        self.assertEqual(
            result["audio"]["continuityClassification"],
            "announced_quiet_stillness",
        )

    def test_unannounced_stillness_is_still_a_blackout(self):
        warmup = quality_sample(2.0, 30)
        steady = quality_sample(10.0, 40)
        steady["audio"]["plcInvocations"] = 20
        steady["audio"]["plcPacketsFed"] = 20
        steady["audio"]["underrunFrames"] = 15_070
        steady["audio"]["declickProtectedUnderrunFrames"] = 15_070
        result = self.analyze(steady, samples=[warmup, steady])
        self.assertIn("audio_steady_state_late_or_plc", result["failures"])

    def test_announced_quiet_does_not_excuse_sustained_late_drops(self):
        warmup = quality_sample(2.0, 30)
        steady = quality_sample(10.0, 40)
        steady["audio"]["hostAnnouncedQuiet"] = True
        steady["audio"]["plcInvocations"] = 20
        steady["audio"]["plcPacketsFed"] = 20
        steady["audio"]["latePacketsDropped"] = 12
        steady["audio"]["underrunFrames"] = 15_070
        steady["audio"]["declickProtectedUnderrunFrames"] = 15_070
        result = self.analyze(steady, samples=[warmup, steady])
        self.assertIn("audio_steady_state_late_or_plc", result["failures"])


class TwinRendererPinTests(unittest.TestCase):
    """The cross-language pin, python side.

    These digests are the same constants asserted by
    SyntheticMotionReferenceTests.testTwinRenderersAgreeByteForByte in
    the Swift suite. MotionFrames (the numpy twin of the GTK canvas)
    and the client's SyntheticMotionReference must render the authored
    frame byte-for-byte; a drift in either renderer moves exactly one
    side of the pin and both suites fail.
    """

    PINS = {
        0: "fec91c8942b63df2264470cd0db2ccc0e485454170edc36ccb9e90b3a43ca2b4",
        257: "9183977edb22c8f8e21554388376ac82fc170da15a1ebb98579b08c9a13c68ff",
        900: "00c770aac5dcfc5d5489c0ee62e32bd8b541105e4b2fca41d9ba8ea463c1c43f",
    }

    def test_numpy_twin_matches_the_pinned_frames(self):
        import hashlib

        definition = json.loads(
            Path(__file__).with_name("motion-definition.json").read_text())
        frames = PRESENTER.MotionFrames(1024, 640, definition)
        for frame_id, expected in self.PINS.items():
            digest = hashlib.sha256(
                frames.render(frame_id).tobytes()).hexdigest()
            self.assertEqual(
                digest, expected,
                f"frame {frame_id} drifted from the pinned glass")


if __name__ == "__main__":
    unittest.main()

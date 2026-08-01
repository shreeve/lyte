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


def quality_sample(elapsed, decoded_frames, psnr=46.0, ssim=0.996):
    fixture = sample("quality-static", 0, ["freshCapture"])
    fixture["elapsedSeconds"] = elapsed
    fixture["video"]["framesDecoded"] = decoded_frames
    fixture["quality"] = {
        "elapsedSeconds": elapsed,
        "decodedFrames": decoded_frames,
        "referenceName": "text-100",
        "sourceWidth": 1920,
        "sourceHeight": 1080,
        "sourceWitnessSHA256": "fixture",
        "sourceWitnessRDB": 45.2,
        "sourceWitnessGDB": 45.2,
        "sourceWitnessBDB": 45.2,
        "sourceWitnessMinDB": 45.2,
        "sourceWitnessLumaSSIM": 0.9999,
        "decodedWidth": 1920,
        "decodedHeight": 1080,
        "psnrRDB": psnr + 1,
        "psnrGDB": psnr,
        "psnrBDB": psnr + 0.5,
        "psnrMinDB": psnr,
        "lumaSSIM": ssim,
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
    return fixture


def pipeline_sample(elapsed, decoded_frames, psnr=41.0, ssim=0.996):
    fixture = quality_sample(elapsed, decoded_frames, psnr, ssim)
    fixture["workload"] = "motion-pipeline"
    fixture["motionLeg"] = "synthetic-host-pipeline"
    fixture["quality"]["referenceName"] = "synthetic-motion-v1"
    fixture["quality"]["syntheticFrameID"] = decoded_frames
    fixture["quality"]["phaseMatched"] = True
    fixture["hostPipeline"] = {
        "sourceFrames": decoded_frames,
        "sourceDeadlineLateness": {"p99Milliseconds": 0.2},
    }
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

    def test_synthetic_pipeline_leg_passes_without_compositor_evidence(self):
        fixtures = [
            pipeline_sample(1.0, 60),
            pipeline_sample(2.0, 120),
            pipeline_sample(4.0, 240),
            pipeline_sample(5.0, 300),
        ]
        result = self.analyze(fixtures[-1], samples=fixtures)
        self.assertNotIn("motion_pipeline_provenance_missing", result["failures"])
        self.assertNotIn(
            "motion_pipeline_compositor_evidence_mixed", result["failures"])
        self.assertNotIn(
            "motion_pipeline_fresh_cadence_failed", result["failures"])

    def test_compositor_and_synthetic_pipeline_legs_cannot_be_mixed(self):
        fixture = pipeline_sample(5.0, 300)
        fixture["motionSource"] = {
            "pass": True,
            "dimensionsExact": True,
            "skippedSourceFrames": 0,
            "gapP99Milliseconds": 17,
            "phaseDriftP99Milliseconds": 1,
        }
        result = self.analyze(fixture)
        self.assertIn(
            "motion_pipeline_compositor_evidence_mixed", result["failures"])

        compositor = sample("motion", 0, ["freshCapture"] * 4)
        compositor["motionLeg"] = "synthetic-host-pipeline"
        result = self.analyze(compositor)
        self.assertIn("motion_compositor_provenance_mixed", result["failures"])

    def test_synthetic_source_deadline_jitter_precedes_transport(self):
        fixture = pipeline_sample(5.0, 300)
        fixture["hostPipeline"]["sourceDeadlineLateness"][
            "p99Milliseconds"] = 12.0
        fixture["frames"][-1]["transitStretchMilliseconds"] = 20.0
        result = self.analyze(fixture)
        self.assertIn(
            "motion_pipeline_source_deadline_failed", result["failures"])
        self.assertEqual(
            result["motion"]["firstJaggedBoundary"], "synthetic_host_source")

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
        steady = json.loads(json.dumps(warmup))
        steady["elapsedSeconds"] = 10.0
        steady["audio"]["plcInvocations"] = 1
        steady["audio"]["plcPacketsFed"] = 1
        steady["audio"]["latePacketsDropped"] = 1
        result = self.analyze(steady, samples=[warmup, steady])
        self.assertIn("audio_steady_state_late_or_plc", result["failures"])

    def test_bounded_steady_blackout_at_ceiling_is_mitigated(self):
        warmup = sample("motion", 0, ["freshCapture"])
        warmup["elapsedSeconds"] = 2.0
        warmup["audio"]["targetPackets"] = 20
        steady = json.loads(json.dumps(warmup))
        steady["elapsedSeconds"] = 10.0
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

    def test_cadence_clean_but_blurry_quality_fails(self):
        fixtures = [
            quality_sample(1.0, 60, psnr=41.0),
            quality_sample(2.0, 120, psnr=42.0),
            quality_sample(4.0, 240, psnr=44.9),
            quality_sample(5.0, 300, psnr=44.9),
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

    def test_fractionally_scaled_source_witness_fails_before_encoder(self):
        fixtures = [
            quality_sample(1.0, 10, psnr=46.0),
            quality_sample(2.0, 20, psnr=46.0),
            quality_sample(4.0, 30, psnr=46.0),
            quality_sample(5.0, 30, psnr=46.0),
        ]
        for fixture in fixtures:
            fixture["quality"]["sourceWitnessMinDB"] = 10.51
            fixture["quality"]["sourceWitnessLumaSSIM"] = 0.60639
        result = self.analyze(fixtures[-1], samples=fixtures)
        self.assertIn("quality_source_witness_failed", result["failures"])
        self.assertNotIn("quality_converged_gate_failed", result["failures"])


if __name__ == "__main__":
    unittest.main()

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
                "readyGapMilliseconds": 16.0,
                "transitStretchMilliseconds": 0.2,
            }
        )
    return {
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


if __name__ == "__main__":
    unittest.main()

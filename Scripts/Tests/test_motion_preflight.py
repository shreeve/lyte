#!/usr/bin/env python3
"""Deterministic tests for Scripts/motion_preflight.py."""

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "motion_preflight.py"
spec = importlib.util.spec_from_file_location("motion_preflight", SCRIPT)
preflight = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preflight)

WIDTH, HEIGHT, SCALE = 2048, 1280, 2.0
PERIOD_US = 1_000_000 / 60


def tick(frame_id):
    return {
        "event": "sourceTick",
        "frameID": frame_id,
        "textureWidth": WIDTH,
        "textureHeight": HEIGHT,
        "allocationWidthPoints": WIDTH / SCALE,
        "allocationHeightPoints": HEIGHT / SCALE,
        "skippedSourceFrames": 0,
    }


def presentation(frame_id, micros):
    return {
        "event": "presentation",
        "frameID": frame_id,
        "actualPresentationMicroseconds": micros,
    }


def clean_motion(frames=180, late_frames=(), late_by_us=0):
    events = []
    for frame_id in range(frames):
        events.append(tick(frame_id))
        at = 1_000_000 + round(frame_id * PERIOD_US)
        if frame_id in late_frames:
            at += late_by_us
        events.append(presentation(frame_id, at))
    return events


class MotionPreflightTests(unittest.TestCase):
    def judge(self, events, freeze=None):
        return preflight.judge(events, WIDTH, HEIGHT, SCALE, freeze)

    def test_clean_60hz_motion_passes(self):
        result = self.judge(clean_motion())
        self.assertTrue(result["pass"], result)
        self.assertLess(result["gapP99Milliseconds"], 17.0)

    def test_late_presentations_fail_the_cadence(self):
        # p99 over 180 samples tolerates one outlier; three is a real tail.
        result = self.judge(clean_motion(late_frames=(40, 90, 140), late_by_us=40_000))
        self.assertFalse(result["pass"])
        self.assertGreater(result["phaseDriftP99Milliseconds"], 8)

    def test_too_few_warm_samples_fail_with_a_reason(self):
        result = self.judge(clean_motion(frames=60))
        self.assertFalse(result["pass"])
        self.assertIn("fewer than 120", result["error"])

    def test_scaled_allocation_mismatch_fails_dimensions(self):
        events = clean_motion()
        events[0]["allocationWidthPoints"] += 3
        result = self.judge(events)
        self.assertFalse(result["dimensionsExact"])
        self.assertFalse(result["pass"])

    def test_frozen_frame_passes_on_exact_dimensions(self):
        events = [tick(900), presentation(900, 1_000_000), tick(900)]
        result = self.judge(events, freeze=900)
        self.assertTrue(result["pass"], result)
        self.assertEqual(result["kind"], "frozen-frame")

    def test_frozen_source_showing_another_frame_fails(self):
        result = self.judge([tick(900), tick(901)], freeze=900)
        self.assertFalse(result["pass"])
        self.assertIn("foreign frame", result["error"])

    def test_every_failure_still_writes_a_summary(self):
        with tempfile.TemporaryDirectory() as scratch:
            log = Path(scratch) / "source.jsonl"
            summary = Path(scratch) / "summary.json"
            log.write_text("\n".join(json.dumps(e) for e in clean_motion(frames=10)))
            status = preflight.main(
                [str(log), str(summary), str(WIDTH), str(HEIGHT), str(SCALE), ""])
            self.assertEqual(status, 1)
            self.assertFalse(json.loads(summary.read_text())["pass"])

            status = preflight.main(
                [str(Path(scratch) / "missing.jsonl"), str(summary),
                 str(WIDTH), str(HEIGHT), str(SCALE), ""])
            self.assertEqual(status, 1)
            self.assertIn("unreadable", json.loads(summary.read_text())["error"])


if __name__ == "__main__":
    unittest.main()

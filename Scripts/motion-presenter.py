#!/usr/bin/env python3
"""Deterministic, frame-clock-driven GTK4 motion source for Lyte gates.

One authored frame, two painters: frame_shapes() is the frame as an ordered
list of filled rectangles; the GTK canvas paints it on the glass and
MotionFrames paints the identical list into numpy, so the SHA-256 pins in
Scripts/Tests/test_analyze_app_benchmark.py (shared with the Swift mirror,
SyntheticMotionReferenceTests) hold what the glass receives.

The gi/GTK imports live inside run_presenter() so this module imports on
machines without GTK (the Mac test rig) for MotionFrames alone.
"""

import argparse
import json
import time
from pathlib import Path

import numpy as np

GRID = (74, 74, 74)
MARKER_ONE = (255, 255, 255)
MARKER_ZERO = (0, 0, 0)
MARKER_START = (0, 255, 255)
MARKER_END = (255, 0, 255)


def bounce(frame_id, speed, extent, object_extent):
    span = max(1, extent - object_extent)
    phase = (frame_id * abs(speed)) % (2 * span)
    position = phase if phase <= span else 2 * span - phase
    return position if speed >= 0 else span - position


def static_shapes(width, height, definition):
    """The background and a high-frequency registration grid, so any
    compositor scaling is measurable before Lyte enters the experiment.
    Each shape is (rgb, x, y, width, height), painted in order."""
    yield definition["background"], 0, 0, width, height
    for x in range(0, width, 64):
        yield GRID, x, 0, 1, height
    for y in range(0, height, 64):
        yield GRID, 0, y, width, 1


def frame_shapes(frame_id, width, height, definition):
    """The moving shapes of frame_id, drawn over static_shapes()."""
    d = definition
    colors = d["colors"]
    for index, color in enumerate(colors):
        x = (frame_id * d["verticalLineSpeedPixelsPerFrame"]
             + index * 313) % width
        y = (frame_id * d["horizontalLineSpeedPixelsPerFrame"]
             + index * 197) % height
        yield color, x, 0, 5, height
        yield color, 0, y, width, 5

    box_w, box_h = 240, 150
    vx, vy = d["boxVelocityPixelsPerFrame"]
    box_x = bounce(frame_id, vx, width, box_w)
    box_y = bounce(frame_id, vy, height, box_h)
    yield colors[0], box_x, box_y, box_w, box_h
    yield colors[1], box_x + 12, box_y + 12, box_w - 24, box_h - 24

    radius = 84
    cvx, cvy = d["circleVelocityPixelsPerFrame"]
    cx = bounce(frame_id, cvx, width, radius * 2)
    cy = bounce(frame_id, cvy, height, radius * 2)
    yield colors[3], cx, cy, radius * 2, radius * 2

    # The frame marker: start and end sentinels bound little-endian bit
    # blocks of markerBlockPixels square, so the ID survives HEVC.
    bits = d["markerBits"]
    block = d["markerBlockPixels"]
    yield MARKER_START, 0, 0, block, block
    for bit in range(bits):
        yield (MARKER_ONE if frame_id >> bit & 1 else MARKER_ZERO,
               (bit + 1) * block, 0, block, block)
    yield MARKER_END, (bits + 1) * block, 0, block, block


class MotionFrames:
    """The authored frames as BGRA numpy arrays."""

    def __init__(self, width, height, definition):
        self.width = width
        self.height = height
        self.definition = definition
        self.base = np.empty((height, width, 4), dtype=np.uint8)
        self.paint(self.base, static_shapes(width, height, definition))

    @staticmethod
    def paint(frame, shapes):
        for (r, g, b), x, y, width, height in shapes:
            frame[y:y + height, x:x + width] = (b, g, r, 255)

    def render(self, frame_id):
        frame = self.base.copy()
        self.paint(frame, frame_shapes(
            frame_id, self.width, self.height, self.definition))
        return frame


def run_presenter(args, definition):
    import gi

    gi.require_version("Gdk", "4.0")
    gi.require_version("Graphene", "1.0")
    gi.require_version("Gtk", "4.0")
    from gi.repository import Gdk, GLib, Graphene, Gtk

    class MotionCanvas(Gtk.Widget):
        def __init__(self, physical_width, physical_height, definition):
            super().__init__()
            self.physical_width = physical_width
            self.physical_height = physical_height
            self.definition = definition
            self.frame_id = 0
            self.set_hexpand(True)
            self.set_vexpand(True)

        @staticmethod
        def color(color):
            rgba = Gdk.RGBA()
            rgba.red, rgba.green, rgba.blue = (
                component / 255 for component in color)
            rgba.alpha = 1
            return rgba

        def do_snapshot(self, snapshot):
            w, h = self.physical_width, self.physical_height
            sx, sy = self.get_width() / w, self.get_height() / h
            for color, x, y, width, height in (
                    *static_shapes(w, h, self.definition),
                    *frame_shapes(self.frame_id, w, h, self.definition)):
                snapshot.append_color(self.color(color), Graphene.Rect().init(
                    x * sx, y * sy, width * sx, height * sy))

    class MotionApp(Gtk.Application):
        def __init__(self, args, definition):
            super().__init__(application_id="dev.shreeve.LyteMotionPresenter")
            self.args = args
            self.definition = definition
            self.frame_id = -1
            self.tick_id = 0
            self.origin_presentation_us = None
            self.origin_frame_counter = None
            self.origin_tick_ns = None
            self.period_ns = round(1_000_000_000 / definition["fps"])
            self.log = open(args.log, "w", buffering=1)
            self.canvas = None
            self.pending_presentations = {}

        def do_activate(self):
            window = Gtk.ApplicationWindow(application=self)
            self.canvas = MotionCanvas(
                self.args.width, self.args.height, self.definition)
            window.set_child(self.canvas)
            window.set_cursor_from_name("none")
            window.fullscreen()
            window.present()
            self.canvas.add_tick_callback(self.on_tick)

        def on_tick(self, widget, frame_clock):
            frame_clock_us = frame_clock.get_frame_time()
            tick_ns = time.monotonic_ns()
            tick_id = self.tick_id
            self.tick_id += 1
            for counter, source_frame_id in list(
                    self.pending_presentations.items()):
                timings = frame_clock.get_timings(counter)
                if timings is None or not timings.get_complete():
                    continue
                self.log.write(json.dumps({
                    "event": "presentation",
                    "frameID": source_frame_id,
                    "gdkFrameCounter": counter,
                    "actualPresentationMicroseconds":
                        timings.get_presentation_time(),
                    "predictedPresentationMicroseconds":
                        timings.get_predicted_presentation_time(),
                    "refreshIntervalMicroseconds":
                        timings.get_refresh_interval(),
                }, separators=(",", ":")) + "\n")
                del self.pending_presentations[counter]
            refresh_us, predicted_us = frame_clock.get_refresh_info(
                frame_clock_us)
            frame_counter = frame_clock.get_frame_counter()
            if predicted_us <= 0:
                self.canvas.queue_draw()
                return GLib.SOURCE_CONTINUE
            if self.origin_presentation_us is None:
                self.origin_presentation_us = predicted_us
                self.origin_frame_counter = frame_counter
                self.origin_tick_ns = tick_ns
            if self.args.freeze is not None:
                # A frozen presenter is the static quality witness: one
                # authored frame on the glass, verified once, then held.
                target_frame = self.args.freeze
            else:
                target_frame = round(
                    (predicted_us - self.origin_presentation_us)
                    * self.definition["fps"] / 1_000_000)
            if target_frame <= self.frame_id:
                # Frozen: keep the frame clock alive only long enough to
                # collect the held frame's presentation evidence.
                if self.args.freeze is not None and self.pending_presentations:
                    self.canvas.queue_draw()
                return GLib.SOURCE_CONTINUE
            skipped = max(0, target_frame - self.frame_id - 1)
            self.frame_id = target_frame
            deadline_ns = self.origin_tick_ns + self.frame_id * self.period_ns
            self.pending_presentations[frame_counter] = self.frame_id
            self.canvas.frame_id = self.frame_id
            self.canvas.queue_draw()
            allocation_width = self.canvas.get_width()
            allocation_height = self.canvas.get_height()
            self.log.write(json.dumps({
                "event": "sourceTick",
                "frameID": self.frame_id,
                "tickID": tick_id,
                "gdkFrameCounter": frame_counter,
                "frameClockMicroseconds": frame_clock_us,
                "tickMonotonicNanoseconds": tick_ns,
                "predictedPresentationMicroseconds": predicted_us,
                "refreshIntervalMicroseconds": refresh_us,
                "sourceDeadlineNanoseconds": deadline_ns,
                "sourceLatenessMicroseconds": (tick_ns - deadline_ns) / 1000,
                "skippedSourceFrames": skipped,
                "textureWidth": self.args.width,
                "textureHeight": self.args.height,
                "allocationWidthPoints": allocation_width,
                "allocationHeightPoints": allocation_height,
            }, separators=(",", ":")) + "\n")
            return GLib.SOURCE_CONTINUE

    MotionApp(args, definition).run([])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--definition", required=True)
    parser.add_argument("--width", required=True, type=int)
    parser.add_argument("--height", required=True, type=int)
    parser.add_argument("--log", required=True)
    parser.add_argument(
        "--freeze", type=int, default=None,
        help="present this frame ID once and hold it (static witness)")
    args = parser.parse_args()
    definition = json.loads(Path(args.definition).read_text())
    run_presenter(args, definition)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Deterministic, frame-clock-driven GTK4 motion source for Lyte gates.

Two renderers, one authored frame: the GTK canvas puts the frame on the
glass; MotionFrames renders the identical bytes in numpy so tests (and
the Swift client mirror, pinned by shared SHA-256 fixtures) can hold the
glass accountable pixel-for-pixel. Any edit to one renderer must land in
both — the cross-language fixture pins in test_analyze_app_benchmark.py
and SyntheticMotionReferenceTests fail loudly if they drift.

The gi/GTK imports live inside run_presenter() so this module imports on
machines without GTK (the Mac test rig) for MotionFrames alone.
"""

import argparse
import json
import time
from pathlib import Path

import numpy as np


def bounce(frame_id, speed, extent, object_extent):
    span = max(1, extent - object_extent)
    phase = (frame_id * abs(speed)) % (2 * span)
    position = phase if phase <= span else 2 * span - phase
    return position if speed >= 0 else span - position


class MotionFrames:
    """Byte-exact numpy twin of the GTK canvas (BGRA, definition colors
    are [r, g, b])."""

    def __init__(self, width, height, definition):
        self.width = width
        self.height = height
        self.definition = definition
        r, g, b = definition["background"]
        self.base = np.empty((height, width, 4), dtype=np.uint8)
        self.base[:, :, :] = (b, g, r, 255)
        self.colors = [
            (color[2], color[1], color[0], 255)
            for color in definition["colors"]
        ]
        # Static high-frequency registration grid: any compositor scaling is
        # visible and measurable before Lyte enters the experiment.
        self.base[::64, :, :3] = 74
        self.base[:, ::64, :3] = 74

    def render(self, frame_id, include_marker=True):
        frame = self.base.copy()
        w, h = self.width, self.height
        for index, color in enumerate(self.colors):
            x = (
                frame_id
                * self.definition["verticalLineSpeedPixelsPerFrame"]
                + index * 313
            ) % w
            y = (
                frame_id
                * self.definition["horizontalLineSpeedPixelsPerFrame"]
                + index * 197
            ) % h
            frame[:, x:min(x + 5, w)] = color
            frame[y:min(y + 5, h), :] = color

        box_w, box_h = 240, 150
        vx, vy = self.definition["boxVelocityPixelsPerFrame"]
        box_x = bounce(frame_id, vx, w, box_w)
        box_y = bounce(frame_id, vy, h, box_h)
        frame[box_y:box_y + box_h, box_x:box_x + box_w] = self.colors[0]
        frame[box_y + 12:box_y + box_h - 12,
              box_x + 12:box_x + box_w - 12] = self.colors[1]

        radius = 84
        cvx, cvy = self.definition["circleVelocityPixelsPerFrame"]
        cx = bounce(frame_id, cvx, w, radius * 2) + radius
        cy = bounce(frame_id, cvy, h, radius * 2) + radius
        frame[cy - radius:cy + radius, cx - radius:cx + radius] = \
            self.colors[3]

        # Unambiguous 24-bit frame marker. Fixed cyan/magenta sentinels bound
        # little-endian binary blocks; each block is a full 24×24 source-pixel
        # cell so the ID survives HEVC while a wrong phase remains obvious.
        if include_marker:
            self.draw_marker(frame, frame_id)
        return frame

    def draw_marker(self, frame, frame_id):
        bits = self.definition["markerBits"]
        block = self.definition["markerBlockPixels"]
        marker_width = (bits + 2) * block
        frame[:block, :marker_width] = (0, 0, 0, 255)
        frame[:block, :block] = (255, 255, 0, 255)
        value = frame_id & ((1 << bits) - 1)
        for bit in range(bits):
            x0 = (bit + 1) * block
            pixel = (255, 255, 255, 255) if value & (1 << bit) else (0, 0, 0, 255)
            frame[:block, x0:x0 + block] = pixel
        frame[:block, (bits + 1) * block:marker_width] = (255, 0, 255, 255)


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
            d = self.definition
            w, h = self.physical_width, self.physical_height
            sx, sy = self.get_width() / w, self.get_height() / h

            def rectangle(color, x, y, width, height):
                rect = Graphene.Rect().init(
                    x * sx, y * sy, width * sx, height * sy)
                snapshot.append_color(self.color(color), rect)

            rectangle(d["background"], 0, 0, w, h)
            for x in range(0, w, 64):
                rectangle([74, 74, 74], x, 0, 1, h)
            for y in range(0, h, 64):
                rectangle([74, 74, 74], 0, y, w, 1)

            for index, color in enumerate(d["colors"]):
                x = (
                    self.frame_id * d["verticalLineSpeedPixelsPerFrame"]
                    + index * 313
                ) % w
                y = (
                    self.frame_id * d["horizontalLineSpeedPixelsPerFrame"]
                    + index * 197
                ) % h
                rectangle(color, x, 0, 5, h)
                rectangle(color, 0, y, w, 5)

            box_w, box_h = 240, 150
            vx, vy = d["boxVelocityPixelsPerFrame"]
            box_x = bounce(self.frame_id, vx, w, box_w)
            box_y = bounce(self.frame_id, vy, h, box_h)
            rectangle(d["colors"][0], box_x, box_y, box_w, box_h)
            rectangle(
                d["colors"][1],
                box_x + 12, box_y + 12, box_w - 24, box_h - 24)

            radius = 84
            cvx, cvy = d["circleVelocityPixelsPerFrame"]
            cx = bounce(self.frame_id, cvx, w, radius * 2) + radius
            cy = bounce(self.frame_id, cvy, h, radius * 2) + radius
            rectangle(
                d["colors"][3],
                cx - radius, cy - radius, radius * 2, radius * 2)

            bits = d["markerBits"]
            block = d["markerBlockPixels"]
            rectangle([0, 255, 255], 0, 0, block, block)
            for bit in range(bits):
                rectangle(
                    [255, 255, 255]
                    if self.frame_id & (1 << bit) else [0, 0, 0],
                    (bit + 1) * block, 0, block, block)
            rectangle([255, 0, 255], (bits + 1) * block, 0, block, block)

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
            self.vsync_divisor = max(1, round(args.refresh / definition["fps"]))
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
                # Frozen: keep the frame clock alive just long enough to
                # collect the held frame's presentation evidence, then go
                # truly still so the glass shows authored stillness.
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
                "monitorRefreshHz": self.args.refresh,
                "vsyncDivisor": self.vsync_divisor,
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
    parser.add_argument("--refresh", required=True, type=float)
    parser.add_argument("--log", required=True)
    parser.add_argument(
        "--freeze", type=int, default=None,
        help="present this frame ID once and hold it (static witness)")
    args = parser.parse_args()
    definition = json.loads(Path(args.definition).read_text())
    run_presenter(args, definition)


if __name__ == "__main__":
    main()

/// Recover the cursor hotspot inside a content-cropped KMS cursor image.
///
/// i915 exposes no HOTSPOT_X/Y plane props. The compositor places the plane
/// at `pointer − hotspot` (in the full buffer), so:
///
///     hotspot_in_crop = pointer − planeCrtc − cropOrigin
///
/// Reading `CRTC_X`/`CRTC_Y` requires `DRM_CLIENT_CAP_ATOMIC`; without it
/// the plane position is unknown (never a real `(0,0)`). Then the hotspot
/// falls back to the content top-left, correct for the common arrow tip.
public enum CursorHotspot {
    public struct Point: Sendable, Equatable {
        public var x: Int
        public var y: Int

        public init(x: Int, y: Int) {
            self.x = x
            self.y = y
        }
    }

    /// Derive a hotspot inside an image of `width`×`height`.
    ///
    /// - Parameters:
    ///   - pointer: last injected absolute pointer in device pixels, if any.
    ///   - planeCrtc: cursor plane CRTC position; `nil` when the atomic
    ///     props are missing.
    ///   - crop: content-box origin inside the full cursor buffer.
    ///   - width/height: content-cropped image size (must be ≥ 1).
    public static func derive(
        pointer: Point?,
        planeCrtc: Point?,
        crop: Point,
        width: Int,
        height: Int
    ) -> Point {
        precondition(width >= 1 && height >= 1)
        var hx = 0
        var hy = 0
        if let pointer, let planeCrtc {
            hx = pointer.x - planeCrtc.x - crop.x
            hy = pointer.y - planeCrtc.y - crop.y
        }
        return Point(
            x: min(max(hx, 0), width - 1),
            y: min(max(hy, 0), height - 1))
    }

    /// True when a rest recheck may recompute the hotspot from a settled
    /// plane. A missing plane must not "correct" a tip fallback; a real
    /// `(0,0)` plane may.
    public static func canRecheck(planeCrtc: Point?) -> Bool {
        planeCrtc != nil
    }
}

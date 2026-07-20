import Foundation

/// Policy engine v1 (PLAN §5.4, D2): every streaming number is *derived* from
/// intent, never dialed directly. v1 covers mode × dial on a Local network;
/// telemetry-driven bitrate probing and Remote handling arrive with the
/// doctor (M6).
public enum StreamMode: String, Sendable, Codable, CaseIterable {
    case work   // desktop use: sharpness + smoothness over latency
    case play   // gaming: latency over everything
}

public struct PolicyInput: Sendable {
    public var mode: StreamMode
    /// Quality ⇄ latency dial, −1…+1, default 0 (D2: one slider per mode).
    public var dial: Double
    /// Host's native display, if known (serverinfo / probe).
    public var hostDisplay: (width: Int, height: Int, fps: Int)?
    /// Client panel in device pixels, aspect-fit target for Play.
    public var clientPanel: (width: Int, height: Int)?
    /// Measured bitrate ceiling for this host (kbps), learned from sessions
    /// that hit FEC-exceeded loss. nil = no measurement yet (D2: bitrate is
    /// f(measured headroom), and this is the measurement arriving).
    public var bitrateCeilingKbps: Int?

    public init(mode: StreamMode, dial: Double = 0,
                hostDisplay: (width: Int, height: Int, fps: Int)? = nil,
                clientPanel: (width: Int, height: Int)? = nil,
                bitrateCeilingKbps: Int? = nil) {
        self.mode = mode
        self.dial = max(-1, min(1, dial))
        self.hostDisplay = hostDisplay
        self.clientPanel = clientPanel
        self.bitrateCeilingKbps = bitrateCeilingKbps
    }
}

public struct PolicyOutput: Sendable {
    public let width: Int
    public let height: Int
    public let fps: Int
    public let bitrateKbps: Int
    public let audioBufferMs: Int
    public let mouseLockedByDefault: Bool
    public let fullscreenByDefault: Bool
    /// Human-readable derivation trail — the doctor pane shows *why* (D2).
    public let rationale: [String]
}

public enum Policy {
    public static func derive(_ input: PolicyInput) -> PolicyOutput {
        var why: [String] = []

        // Resolution: Work = host-native 1:1 (crisp text is the whole point);
        // Play = client panel aspect-fit, capped at host native.
        let fallback = (width: 2048, height: 1280, fps: 60)
        let host = input.hostDisplay ?? fallback
        var width = host.width, height = host.height
        switch input.mode {
        case .work:
            why.append("resolution \(width)×\(height): host-native for 1:1 text")
        case .play:
            if let panel = input.clientPanel, panel.width < host.width {
                let scale = Double(panel.width) / Double(host.width)
                width = panel.width
                height = Int((Double(host.height) * scale / 2).rounded()) * 2
                why.append("resolution \(width)×\(height): client panel fit (host \(host.width)×\(host.height))")
            } else {
                why.append("resolution \(width)×\(height): host-native (client panel ≥ host)")
            }
        }

        let fps = host.fps
        why.append("\(fps) fps: host refresh")

        // Bitrate: conservative base scaled by pixel rate, biased by the dial
        // (×0.6 at −1 latency … ×1.6 at +1 quality). Headroom probing is M6.
        let pixelRate = Double(width * height * fps)
        let base = pixelRate / 1_000_000 * 0.28          // ≈44 Mbps at 2048×1280@60
        let dialFactor = 1.0 + input.dial * 0.6
        var bitrateKbps = Int((base * dialFactor).rounded()) * 1000
        why.append("bitrate \(bitrateKbps / 1000) Mbps: pixel-rate base ×\(String(format: "%.1f", dialFactor)) dial")
        if let ceiling = input.bitrateCeilingKbps, ceiling < bitrateKbps {
            bitrateKbps = ceiling
            why.append("bitrate lowered to \(ceiling / 1000) Mbps: this host dropped packets at higher rates")
        }

        // Audio buffer: Work rides comfort, Play rides the edge (PLAN §4.2).
        let audioBufferMs: Int
        switch input.mode {
        case .work:
            audioBufferMs = 50 + Int(input.dial * 10)    // 40–60 ms
        case .play:
            audioBufferMs = 15 + Int(input.dial * 5)     // 10–20 ms
        }
        why.append("audio buffer \(audioBufferMs) ms: \(input.mode.rawValue) mode")

        return PolicyOutput(width: width, height: height, fps: fps,
                            bitrateKbps: bitrateKbps,
                            audioBufferMs: audioBufferMs,
                            mouseLockedByDefault: input.mode == .play,
                            fullscreenByDefault: input.mode == .play,
                            rationale: why)
    }
}

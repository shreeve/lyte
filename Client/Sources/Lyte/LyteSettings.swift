import SwiftUI

/// App settings (⌘,). One pane so far: Video — the stall cushion,
/// born from the 2026-08-01 Wi-Fi hunt. The slider sets the playout
/// delay CEILING; the adaptive machinery still starts near minimum
/// and only grows on measured lateness, so a clean link never pays
/// the cushion at all.
struct LyteSettingsView: View {
    @AppStorage(ConnectionModel.playoutCushionKey)
    private var cushionMilliseconds = ConnectionModel.playoutCushionDefault

    /// Stalls are time-based (the radio doesn't care about refresh
    /// rate), so the KNOB stays in milliseconds — this readout just
    /// translates it into frames at a 60 fps reference so the number
    /// has a shape: 50 ms ≈ 3 frames.
    private var cushionReadout: String {
        guard cushionMilliseconds > 0 else { return "0 ms — cushion off" }
        let frames = Double(cushionMilliseconds) * 60 / 1_000
        let tenths = (frames * 10).rounded() / 10
        let count = tenths == tenths.rounded()
            ? String(Int(tenths))
            : String(format: "%.1f", tenths)
        let noun = tenths == 1 ? "frame" : "frames"
        return "\(cushionMilliseconds) ms ≈ \(count) \(noun) at 60 fps"
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Stall cushion") {
                    let bounds = ConnectionModel.playoutCushionRange
                    let range = Double(bounds.lowerBound)
                        ... Double(bounds.upperBound)
                    VStack(alignment: .trailing, spacing: 2) {
                        Slider(
                            value: Binding(
                                get: { Double(cushionMilliseconds) },
                                set: { cushionMilliseconds = Int($0.rounded()) }
                            ),
                            in: range,
                            step: 5
                        )
                        .frame(width: 220)
                        Text(cushionReadout)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Text("How much video delay Lyte may add to absorb "
                    + "network stalls. The delay only grows when stalls "
                    + "are actually measured and shrinks again on a "
                    + "clean link — this sets the ceiling. 50 ms rides "
                    + "out ordinary jitter; ~120 ms swallows a full "
                    + "Wi-Fi scan blackout; 0 turns the cushion off "
                    + "and frames show the instant they arrive. "
                    + "Changes apply live, even mid-stream.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Video")
            }
        }
        .formStyle(.grouped)
        // Grouped forms are list-backed and claim all the height they
        // are offered; hug the single section instead.
        .frame(width: 420, height: 240)
        .navigationTitle("Lyte Settings")
    }
}

import SwiftUI

/// App settings (⌘,). One pane so far: Video — the stall cushion,
/// born from the 2026-08-01 Wi-Fi hunt. The slider sets the playout
/// delay CEILING; the adaptive machinery still starts near minimum
/// and only grows on measured lateness, so a clean link never pays
/// the cushion at all.
struct LyteSettingsView: View {
    @AppStorage(ConnectionModel.playoutCushionKey)
    private var cushionMilliseconds = ConnectionModel.playoutCushionDefault

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
                        Text("\(cushionMilliseconds) ms")
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
                    + "Applies to new connections.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Video")
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .navigationTitle("Lyte Settings")
    }
}

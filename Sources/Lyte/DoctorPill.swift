import SwiftUI
import LyteKit

/// The doctor's face during a stream: a quiet dot in the corner that only
/// asks for attention when something is wrong, and explains itself in plain
/// language when clicked (D4: diagnosis with evidence, never bare numbers).
struct DoctorPill: View {
    let diagnosis: Diagnosis?
    let policy: PolicyOutput?
    @State private var expanded = false
    @State private var hovering = false

    var body: some View {
        if let diagnosis {
            VStack(alignment: .trailing, spacing: 8) {
                Button {
                    expanded.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(color(for: diagnosis.level))
                            .frame(width: 9, height: 9)
                        if hovering || expanded || diagnosis.level != .good {
                            Text(diagnosis.headline)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }

                if expanded {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(diagnosis.evidence, id: \.self) { line in
                            Label(line, systemImage: "waveform.path.ecg")
                                .font(.caption)
                        }
                        ForEach(diagnosis.fixes, id: \.self) { line in
                            Label(line, systemImage: "wrench.adjustable")
                                .font(.caption.weight(.medium))
                        }
                        if let policy {
                            Divider()
                            ForEach(policy.rationale, id: \.self) { line in
                                Label(line, systemImage: "slider.horizontal.3")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: 380, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(12)
        }
    }

    private func color(for level: Diagnosis.Level) -> Color {
        switch level {
        case .good: return .green
        case .fair: return .yellow
        case .poor: return .orange
        }
    }
}

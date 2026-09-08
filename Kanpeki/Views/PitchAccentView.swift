import SwiftUI
import KanpekiDictionary

/// Reading in morae with the Tokyo pitch contour: line above high morae,
/// a downstep bar where the pitch falls, and a trailing ○ for the particle.
struct PitchAccentView: View {
    let pattern: PitchPattern
    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            ForEach(Array(pattern.morae.enumerated()), id: \.offset) { i, m in
                mora(m, high: pattern.high[i], dropAfter: pattern.dropAfter == i)
            }
            mora("○", high: pattern.particleHigh, dropAfter: false).foregroundStyle(.tertiary)
            Text(" \(pattern.kind.rawValue)［\(pattern.accent)］").font(.caption2).foregroundStyle(.secondary).padding(.leading, 4)
        }
    }

    private func mora(_ s: String, high: Bool, dropAfter: Bool) -> some View {
        Text(s).font(.body.monospaced())
            .padding(.horizontal, 1)
            .overlay(alignment: .top) {
                if high { Rectangle().fill(Color.accentColor).frame(height: 1.5).offset(y: -2) }
            }
            .overlay(alignment: .topTrailing) {
                if dropAfter { Rectangle().fill(Color.accentColor).frame(width: 1.5, height: 9).offset(x: 1, y: -2) }
            }
    }
}

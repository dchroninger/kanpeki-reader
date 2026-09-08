import SwiftUI
import KanpekiDictionary

/// Reading in morae with the Tokyo pitch contour: line above high morae,
/// a downstep bar where the pitch falls, and a trailing ○ for the particle.
struct PitchAccentView: View {
    let pattern: PitchPattern
    @State private var drawn = false
    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            ForEach(Array(pattern.morae.enumerated()), id: \.offset) { i, m in
                mora(m, high: pattern.high[i], dropAfter: pattern.dropAfter == i, index: i)
            }
            mora("○", high: pattern.particleHigh, dropAfter: false, index: pattern.morae.count).foregroundStyle(.tertiary)
            Text(" \(pattern.kind.rawValue)［\(pattern.accent)］").font(.caption2).foregroundStyle(.secondary).padding(.leading, 4)
                .opacity(drawn ? 1 : 0).animation(.easeOut.delay(Double(pattern.morae.count) * 0.06 + 0.1), value: drawn)
        }
        .onAppear { drawn = true }
    }

    /// The contour draws left to right, one mora at a time.
    private func mora(_ s: String, high: Bool, dropAfter: Bool, index: Int) -> some View {
        Text(s).font(.body.monospaced())
            .padding(.horizontal, 1)
            .overlay(alignment: .top) {
                if high {
                    Rectangle().fill(Color.accentColor).frame(height: 1.5).offset(y: -2)
                        .scaleEffect(x: drawn ? 1 : 0, anchor: .leading)
                        .animation(.easeOut(duration: 0.18).delay(Double(index) * 0.06), value: drawn)
                }
            }
            .overlay(alignment: .topTrailing) {
                if dropAfter {
                    Rectangle().fill(Color.accentColor).frame(width: 1.5, height: 9).offset(x: 1, y: -2)
                        .scaleEffect(y: drawn ? 1 : 0, anchor: .top)
                        .animation(.easeOut(duration: 0.15).delay(Double(index) * 0.06 + 0.12), value: drawn)
                }
            }
    }
}

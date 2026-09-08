import Foundation

/// Tokyo-dialect pitch: split a kana reading into morae and mark each high
/// or low from the accent number. 0 = 平板 (low, then high, particle high);
/// 1 = 頭高 (high, then low); k = 中高/尾高 (low, high up to mora k, then low).
public struct PitchPattern: Hashable, Sendable {
    public enum Kind: String, Sendable { case heiban = "平板", atamadaka = "頭高", nakadaka = "中高", odaka = "尾高" }
    public let morae: [String]
    public let accent: Int
    /// true = high, one per mora.
    public let high: [Bool]
    /// Whether a following particle would be high (only heiban).
    public let particleHigh: Bool
    public let kind: Kind
    /// Index of the mora after which pitch drops, if any.
    public var dropAfter: Int? { accent == 0 ? nil : accent - 1 }

    public init(reading: String, accent: Int) {
        let m = Self.morae(of: reading)
        morae = m
        self.accent = accent
        if accent == 0 {
            high = m.indices.map { $0 > 0 }; particleHigh = true; kind = .heiban
        } else if accent == 1 {
            high = m.indices.map { $0 == 0 }; particleHigh = false; kind = .atamadaka
        } else {
            high = m.indices.map { $0 >= 1 && $0 < accent }; particleHigh = false
            kind = accent >= m.count ? .odaka : .nakadaka
        }
    }

    /// Small ゃゅょ (and their katakana) attach to the previous mora; ー and っ count as morae.
    public static func morae(of s: String) -> [String] {
        var out: [String] = []
        for ch in s {
            if "ゃゅょャュョぁぃぅぇぉァィゥェォ".contains(ch), !out.isEmpty { out[out.count - 1].append(ch) } else { out.append(String(ch)) }
        }
        return out
    }
}

import Foundation
import NaturalLanguage

/// A run of the recognized text: a dictionary word (with its best match),
/// a particle, or plain text nothing matched.
public struct Segment: Hashable, Sendable, Identifiable {
    public enum Kind: Sendable { case word, particle, plain }
    public var id: Int { start }
    public let start: Int          // character offset
    public let text: String
    public let kind: Kind
    public let matches: [DictionaryMatch]   // empty for .plain; first is the pick
    public var best: DictionaryMatch? { matches.first }
}

public extension JMDict {
    static let particles: Set<String> = ["は", "が", "を", "に", "へ", "と", "で", "の", "も", "か", "ね", "よ", "な", "わ", "ぞ", "ぜ", "さ", "から", "まで", "って", "や", "し", "ば", "けど", "けれど", "のに", "ので", "とか", "だけ", "しか", "でも", "こそ", "ほど", "くらい", "ぐらい", "など", "なんて", "かな", "っけ"]

    /// Segment the whole string once. Apple's tokenizer supplies boundaries;
    /// from each boundary the dictionary scan may run past the token so
    /// inflected verbs stay whole (食べちゃった is one word).
    func segment(_ text: String) -> [Segment] {
        let chars = Array(text)
        guard !chars.isEmpty else { return [] }
        let tok = NLTokenizer(unit: .word)
        tok.setLanguage(.japanese)
        tok.string = text
        var boundaries: [Int] = []
        tok.enumerateTokens(in: text.startIndex..<text.endIndex) { r, _ in
            boundaries.append(text.distance(from: text.startIndex, to: r.lowerBound)); return true
        }
        var out: [Segment] = []
        var i = 0
        var plain = ""; var plainStart = 0
        func flushPlain() { if !plain.isEmpty { out.append(Segment(start: plainStart, text: plain, kind: .plain, matches: [])); plain = "" } }
        while i < chars.count {
            let rest = String(chars[i...])
            // Particles first when the tokenizer agrees this is a token start.
            if boundaries.contains(i) {
                if let p = Self.particles.filter({ rest.hasPrefix($0) }).max(by: { $0.count < $1.count }),
                   !(i + p.count < chars.count && !boundaries.contains(i + p.count) && p.count == 1) {
                    flushPlain()
                    out.append(Segment(start: i, text: p, kind: .particle, matches: lookup(p, maxLength: p.count).filter { $0.matchedLength == p.count }))
                    i += p.count; continue
                }
            }
            let ms = lookup(rest, maxLength: 12)
            if let m = ms.first, m.matchedLength >= 1, boundaries.contains(i) || m.matchedLength > 1 {
                flushPlain()
                let same = ms.filter { $0.matchedLength == m.matchedLength }
                out.append(Segment(start: i, text: String(chars[i..<i + m.matchedLength]), kind: .word, matches: same))
                i += m.matchedLength; continue
            }
            if plain.isEmpty { plainStart = i }
            plain.append(chars[i]); i += 1
        }
        flushPlain()
        return out
    }
}

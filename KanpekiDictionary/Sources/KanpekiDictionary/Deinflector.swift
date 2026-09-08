import Foundation

/// Japanese deinflection: turns an inflected surface form into dictionary
/// form candidates with the chain of reasons. Rule table follows the
/// Yomitan/Yomichan approach (suffix rewrite, applied iteratively); the
/// dictionary lookup is what validates a candidate.
public enum Deinflector {
    public struct Candidate: Hashable, Sendable {
        public let term: String
        public let reasons: [String]
    }

    private struct Rule { let from: String; let to: String; let reason: String }

    // godan endings: (u-row, i-row, a-row, e-row, o-row, ta/te form)
    private static let godan: [(u: String, i: String, a: String, e: String, o: String, ta: String, te: String)] = [
        ("う", "い", "わ", "え", "お", "った", "って"), ("く", "き", "か", "け", "こ", "いた", "いて"),
        ("ぐ", "ぎ", "が", "げ", "ご", "いだ", "いで"), ("す", "し", "さ", "せ", "そ", "した", "して"),
        ("つ", "ち", "た", "て", "と", "った", "って"), ("ぬ", "に", "な", "ね", "の", "んだ", "んで"),
        ("ぶ", "び", "ば", "べ", "ぼ", "んだ", "んで"), ("む", "み", "ま", "め", "も", "んだ", "んで"),
        ("る", "り", "ら", "れ", "ろ", "った", "って"),
    ]

    private static let rules: [Rule] = {
        var r: [Rule] = []
        // --- ichidan (る verbs) ---
        for (suf, reason) in [("ます", "polite"), ("ません", "polite negative"), ("ました", "polite past"), ("ましょう", "polite volitional"),
                              ("ない", "negative"), ("なかった", "negative past"), ("た", "past"), ("て", "te-form"),
                              ("られる", "potential/passive"), ("させる", "causative"), ("よう", "volitional"), ("ろ", "imperative"),
                              ("れば", "conditional"), ("たら", "conditional"), ("たい", "-tai"), ("たくない", "-tai negative"),
                              ("ず", "-zu"), ("ぬ", "archaic negative")] {
            r.append(Rule(from: suf, to: "る", reason: reason))
        }
        // --- godan ---
        for g in godan {
            r.append(Rule(from: g.i + "ます", to: g.u, reason: "polite"))
            r.append(Rule(from: g.i + "ません", to: g.u, reason: "polite negative"))
            r.append(Rule(from: g.i + "ました", to: g.u, reason: "polite past"))
            r.append(Rule(from: g.i + "ましょう", to: g.u, reason: "polite volitional"))
            r.append(Rule(from: g.a + "ない", to: g.u, reason: "negative"))
            r.append(Rule(from: g.a + "なかった", to: g.u, reason: "negative past"))
            r.append(Rule(from: g.ta, to: g.u, reason: "past"))
            r.append(Rule(from: g.te, to: g.u, reason: "te-form"))
            r.append(Rule(from: g.ta + "ら", to: g.u, reason: "conditional"))
            r.append(Rule(from: g.e + "る", to: g.u, reason: "potential"))
            r.append(Rule(from: g.a + "れる", to: g.u, reason: "passive"))
            r.append(Rule(from: g.a + "せる", to: g.u, reason: "causative"))
            r.append(Rule(from: g.o + "う", to: g.u, reason: "volitional"))
            r.append(Rule(from: g.e, to: g.u, reason: "imperative"))
            r.append(Rule(from: g.e + "ば", to: g.u, reason: "conditional"))
            r.append(Rule(from: g.i + "たい", to: g.u, reason: "-tai"))
            r.append(Rule(from: g.i + "たくない", to: g.u, reason: "-tai negative"))
            r.append(Rule(from: g.a + "ず", to: g.u, reason: "-zu"))
            r.append(Rule(from: g.i, to: g.u, reason: "masu stem"))
        }
        // --- i-adjectives ---
        for (suf, reason) in [("くない", "negative"), ("かった", "past"), ("くなかった", "negative past"), ("くて", "te-form"),
                              ("ければ", "conditional"), ("く", "adverbial"), ("さ", "-sa"), ("すぎる", "-sugiru"), ("そう", "-sou"),
                              ("かろう", "volitional")] {
            r.append(Rule(from: suf, to: "い", reason: reason))
        }
        // --- auxiliaries hanging off the te-form (peel, then te-form rules apply) ---
        for (suf, to, reason) in [("ている", "て", "progressive"), ("てる", "て", "progressive"), ("でいる", "で", "progressive"), ("でる", "で", "progressive"),
                                  ("ていた", "て", "progressive past"), ("てた", "て", "progressive past"), ("でいた", "で", "progressive past"),
                                  ("てしまう", "て", "-shimau"), ("ちゃう", "て", "-chau"), ("じゃう", "で", "-chau"), ("でしまう", "で", "-shimau"),
                                  ("ておく", "て", "-oku"), ("とく", "て", "-oku"), ("てみる", "て", "-miru"), ("てくる", "て", "-kuru"), ("ていく", "て", "-iku"),
                                  ("てください", "て", "-kudasai"), ("ておる", "て", "progressive (humble)")] {
            r.append(Rule(from: suf, to: to, reason: reason))
        }
        // --- irregulars ---
        for (from, to, reason) in [("来た", "来る", "past"), ("きた", "くる", "past"), ("来て", "来る", "te-form"), ("きて", "くる", "te-form"),
                                   ("来ない", "来る", "negative"), ("こない", "くる", "negative"), ("来ます", "来る", "polite"), ("きます", "くる", "polite"),
                                   ("来られる", "来る", "potential/passive"), ("こられる", "くる", "potential/passive"), ("来よう", "来る", "volitional"), ("こよう", "くる", "volitional"), ("来い", "来る", "imperative"), ("こい", "くる", "imperative"),
                                   ("した", "する", "past"), ("して", "する", "te-form"), ("しない", "する", "negative"), ("します", "する", "polite"), ("しました", "する", "polite past"),
                                   ("できる", "する", "potential"), ("される", "する", "passive"), ("させる", "する", "causative"), ("しよう", "する", "volitional"), ("しろ", "する", "imperative"), ("せよ", "する", "imperative"),
                                   ("行った", "行く", "past"), ("行って", "行く", "te-form"), ("いった", "いく", "past"), ("いって", "いく", "te-form"),
                                   ("よかった", "いい", "past"), ("よくない", "いい", "negative"), ("よく", "いい", "adverbial")] {
            r.append(Rule(from: from, to: to, reason: reason))
        }
        return r
    }()

    /// All candidates including the term itself, breadth-first, at most `depth` rules deep.
    public static func deinflect(_ term: String, depth: Int = 4) -> [Candidate] {
        var out: [Candidate] = [Candidate(term: term, reasons: [])]
        var seen: Set<String> = [term]
        var frontier = out
        for _ in 0..<depth {
            var next: [Candidate] = []
            for c in frontier {
                for rule in rules where c.term.hasSuffix(rule.from) && c.term.count > rule.from.count - (rule.to.isEmpty ? 0 : 1) {
                    let stem = String(c.term.dropLast(rule.from.count)) + rule.to
                    guard stem.count >= 1, !seen.contains(stem) else { continue }
                    seen.insert(stem)
                    next.append(Candidate(term: stem, reasons: c.reasons + [rule.reason]))
                }
            }
            if next.isEmpty { break }
            out += next; frontier = next
        }
        return out
    }
}

public extension String {
    /// Katakana → hiragana (JMdict readings for native words are hiragana).
    var hiragana: String {
        String(unicodeScalars.map { s -> Character in
            (0x30A1...0x30F6).contains(s.value) ? Character(UnicodeScalar(s.value - 0x60)!) : Character(s)
        })
    }
    var katakana: String {
        String(unicodeScalars.map { s -> Character in
            (0x3041...0x3096).contains(s.value) ? Character(UnicodeScalar(s.value + 0x60)!) : Character(s)
        })
    }
}

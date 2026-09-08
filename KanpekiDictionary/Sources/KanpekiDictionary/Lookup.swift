import Foundation

/// Yomichan-style scan: from the start of `text`, try the longest prefix
/// first, deinflect it, and return every dictionary entry that matches.
public struct DictionaryMatch: Hashable, Sendable, Identifiable {
    public var id: String { "\(entry.id)-\(matchedLength)" }
    public let entry: JMDict.Entry
    /// How many characters of the input this match consumed.
    public let matchedLength: Int
    /// The form that hit the dictionary (after deinflection).
    public let form: String
    public let reasons: [String]
    /// The matched form is the entry's primary kanji or reading (e.g. 本 as
    /// ほん outranks 本 as a secondary spelling of もと).
    public var isPrimaryForm: Bool { entry.kanji.first?.text == form || entry.readings.first?.text == form }
}

public extension JMDict {
    func lookup(_ text: String, maxLength: Int = 24) -> [DictionaryMatch] {
        let chars = Array(text)
        guard !chars.isEmpty else { return [] }
        var results: [DictionaryMatch] = []
        var seenEntries: Set<Int> = []
        for len in stride(from: min(chars.count, maxLength), through: 1, by: -1) {
            let prefix = String(chars[0..<len])
            var forms: [(String, [String])] = []
            for c in Deinflector.deinflect(prefix) {
                forms.append((c.term, c.reasons))
                let h = c.term.hiragana, k = c.term.katakana
                if h != c.term { forms.append((h, c.reasons)) }
                if k != c.term { forms.append((k, c.reasons)) }
            }
            var seenForms: Set<String> = []
            for (form, reasons) in forms where seenForms.insert(form).inserted {
                for e in entries(matching: form) where !seenEntries.contains(e.id) {
                    // A deinflected candidate must land on a verb/adjective.
                    if !reasons.isEmpty && !e.isVerbOrAdjective { continue }
                    seenEntries.insert(e.id)
                    results.append(DictionaryMatch(entry: e, matchedLength: len, form: form, reasons: reasons))
                }
            }
        }
        return results.sorted {
            if $0.matchedLength != $1.matchedLength { return $0.matchedLength > $1.matchedLength }
            if $0.reasons.count != $1.reasons.count { return $0.reasons.count < $1.reasons.count }
            if $0.isPrimaryForm != $1.isPrimaryForm { return $0.isPrimaryForm }
            if $0.entry.common != $1.entry.common { return $0.entry.common }
            return $0.entry.sequence < $1.entry.sequence
        }
    }
}

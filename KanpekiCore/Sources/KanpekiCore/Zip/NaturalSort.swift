import Foundation

/// Version/natural sort, locale-independent. Digit runs compare numerically,
/// everything else by Unicode scalar. This sort **is** the CBZ page-order
/// format: mixed zero-padding scrambles pages under a plain string sort.
public enum NaturalSort {
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let ca = chunks(a), cb = chunks(b)
        for (x, y) in zip(ca, cb) {
            switch (x, y) {
            case (.number(let p, let pz), .number(let q, let qz)):
                if p.count != q.count { return p.count < q.count ? .orderedAscending : .orderedDescending }
                if p != q { return p < q ? .orderedAscending : .orderedDescending }
                if pz != qz { return pz > qz ? .orderedAscending : .orderedDescending } // "01" before "1"
            case (.text(let p), .text(let q)):
                if p != q { return p < q ? .orderedAscending : .orderedDescending }
            case (.number, .text): return .orderedAscending
            case (.text, .number): return .orderedDescending
            }
        }
        if ca.count != cb.count { return ca.count < cb.count ? .orderedAscending : .orderedDescending }
        return .orderedSame
    }

    public static func isOrderedBefore(_ a: String, _ b: String) -> Bool {
        compare(a, b) == .orderedAscending
    }

    private enum Chunk { case number(Substring, Int), text(Substring) }

    private static func chunks(_ s: String) -> [Chunk] {
        var out: [Chunk] = []
        var i = s.startIndex
        while i < s.endIndex {
            let isDigit = s[i].isASCIIDigit
            var j = i
            while j < s.endIndex, s[j].isASCIIDigit == isDigit { j = s.index(after: j) }
            let run = s[i..<j]
            if isDigit {
                let stripped = run.drop(while: { $0 == "0" })
                out.append(.number(stripped.isEmpty ? run.suffix(1) : stripped, run.count - stripped.count))
            } else {
                out.append(.text(run))
            }
            i = j
        }
        return out
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}

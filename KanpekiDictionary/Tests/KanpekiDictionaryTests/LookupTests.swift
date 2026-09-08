import Testing
import Foundation
@testable import KanpekiDictionary

private func dict() throws -> JMDict {
    try JMDict(url: Bundle.module.url(forResource: "jmdict-mini", withExtension: "sqlite", subdirectory: "Fixtures")!)
}

@Suite struct DeinflectorTests {
    @Test(arguments: [
        ("食べました", "食べる", ["polite past"]),
        ("飲んで", "飲む", ["te-form"]),
        ("高くない", "高い", ["negative"]),
        ("行った", "行く", ["past"]),
        ("来た", "来る", ["past"]),
        ("書かなかった", "書く", ["negative past"]),
        ("泳げる", "泳ぐ", ["potential"]),
        ("待っています", "待つ", ["progressive", "polite", "te-form"]),
        ("読みたい", "読む", ["-tai"]),
        ("話せば", "話す", ["conditional"]),
        ("死んじゃった", "死ぬ", ["-chau", "past", "te-form"]),
    ])
    func deinflects(_ surface: String, _ base: String, _ reasons: [String]) {
        let c = Deinflector.deinflect(surface)
        let hit = c.first { $0.term == base }
        #expect(hit != nil, "\(surface) → \(base) not among \(c.map(\.term).prefix(12))")
        if let hit { #expect(Set(hit.reasons) == Set(reasons), "\(hit.reasons)") }
    }

    @Test func kanaConversion() {
        #expect("タベル".hiragana == "たべる"); #expect("たべる".katakana == "タベル"); #expect("食べる".hiragana == "食べる")
    }
}

@Suite struct LookupTests {
    @Test func exactAndInflected() async throws {
        let d = try dict()
        let m = await d.lookup("食べました")
        #expect(m.first?.entry.headword == "食べる")
        #expect(m.first?.matchedLength == 5)
        #expect(m.first?.reasons == ["polite past"])
        #expect(m.first?.entry.senses.first?.glosses.first == "to eat")
    }

    @Test func scansLongestPrefix() async throws {
        let d = try dict()
        let m = await d.lookup("日本の学校")
        #expect(m.first?.entry.headword == "日本" && m.first?.matchedLength == 2)
        // a shorter prefix is still offered when it is a word
        let n = await d.lookup("本を読む")
        #expect(n.first?.entry.headword == "本" && n.first?.matchedLength == 1)
    }

    @Test func readingLookupAndKatakana() async throws {
        let d = try dict()
        #expect(await d.lookup("たべる").first?.entry.headword == "食べる")
        #expect(await d.lookup("タベル").first?.entry.headword == "食べる")
    }

    @Test func nounsAreNotDeinflected() async throws {
        let d = try dict()
        // 先生 must not be reported as an inflection of anything.
        let m = await d.lookup("先生")
        #expect(m.first?.reasons.isEmpty == true)
    }

    @Test func describesEntities() async throws {
        let d = try dict()
        #expect(await d.describe("v1").lowercased().contains("ichidan"))
    }
}

@Suite struct PitchTests {
    @Test func patterns() {
        let a = PitchPattern(reading: "あめ", accent: 1)       // 雨: HL
        #expect(a.high == [true, false] && a.kind == .atamadaka)
        let h = PitchPattern(reading: "はし", accent: 2)       // 橋: LH, drop after → odaka
        #expect(h.high == [false, true] && h.kind == .odaka && !h.particleHigh)
        let g = PitchPattern(reading: "がっこう", accent: 0)   // 学校: LHHH heiban
        #expect(g.high == [false, true, true, true] && g.kind == .heiban && g.particleHigh)
        let t = PitchPattern(reading: "たべる", accent: 2)     // 食べる: LHL nakadaka
        #expect(t.high == [false, true, false] && t.kind == .nakadaka)
        #expect(PitchPattern.morae(of: "きょう") == ["きょ", "う"])
        #expect(PitchPattern.morae(of: "とうきょう") == ["と", "う", "きょ", "う"])
    }

    @Test func lookupFromDictionary() async throws {
        let d = try dict()
        #expect(await d.pitchAccents(headword: "食べる", reading: "たべる") == [2])
        #expect(await d.pitchAccents(headword: "雨", reading: "あめ") == [1])
        let e = try #require(await d.lookup("学校").first?.entry)
        #expect(await d.pitchAccents(for: e) == [0])
    }
}

@Suite struct SegmenterTests {
    @Test func segmentsSentence() async throws {
        let d = try dict()
        let segs = await d.segment("私は日本の学校で本を読む")
        let texts = segs.map { "\($0.text):\($0.kind)" }
        #expect(texts == ["私:word", "は:particle", "日本:word", "の:particle", "学校:word", "で:particle", "本:word", "を:particle", "読む:word"], "\(texts)")
    }

    @Test func keepsInflectedVerbWhole() async throws {
        let d = try dict()
        let segs = await d.segment("寿司を食べました")
        #expect(segs.map(\.text) == ["寿司", "を", "食べました"], "\(segs.map(\.text))")
        #expect(segs.last?.best?.entry.headword == "食べる")
        #expect(segs.last?.best?.reasons == ["polite past"])
    }

    @Test func unknownRunsStayPlain() async throws {
        let d = try dict()
        let segs = await d.segment("ｘｙｚ雨")
        #expect(segs.first?.kind == .plain)
        #expect(segs.last?.text == "雨" && segs.last?.kind == .word)
    }
}

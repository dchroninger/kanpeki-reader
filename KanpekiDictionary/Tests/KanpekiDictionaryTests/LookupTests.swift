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

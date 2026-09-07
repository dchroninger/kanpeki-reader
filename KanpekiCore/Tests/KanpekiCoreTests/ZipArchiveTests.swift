import Testing
import Foundation
@testable import KanpekiCore

private func fixture(_ name: String) -> URL {
    Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
}

@Suite struct ZipArchiveTests {
    @Test(arguments: ["stored.zip", "deflate.zip", "zip64.zip"])
    func pagesInNaturalOrder(_ name: String) throws {
        let z = try ZipArchive(url: fixture(name))
        #expect(z.pages.map(\.name) == ["1.png", "2.png", "10.png", "cover.png"])
        #expect(z.entries.count == 7)
        let d = try z.pageData(1)
        #expect(d.count > 8 && d.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        // decode roundtrip on every page
        for i in z.pages.indices { _ = try z.pageData(i) }
    }

    @Test func storedIsZeroCopySlice() throws {
        let z = try ZipArchive(url: fixture("stored.zip"))
        let e = z.pages[0]
        #expect(e.method == .stored)
        let d = try z.data(for: e)
        #expect(UInt64(d.count) == e.uncompressedSize)
    }

    @Test func deflateInflates() throws {
        let z = try ZipArchive(url: fixture("deflate.zip"))
        let e = try #require(z.entry(named: "ComicInfo.xml"))
        #expect(e.method == .deflate)
        let s = String(decoding: try z.data(for: e), as: UTF8.self)
        #expect(s.contains("<Series>テスト</Series>"))
    }

    @Test func contentIDIsStableAcrossURL() throws {
        let a = try ZipArchive(url: fixture("stored.zip"))
        let tmp = FileManager.default.temporaryDirectory.appending(path: "renamed-\(UUID()).cbz")
        try FileManager.default.copyItem(at: fixture("stored.zip"), to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let b = try ZipArchive(url: tmp)
        #expect(a.contentID == b.contentID)
        #expect(a.contentID != (try ZipArchive(url: fixture("deflate.zip"))).contentID)
        #expect(a.contentID.rawValue.count == 64)
    }

    @Test func notAZip() {
        #expect(throws: ZipArchive.ZipError.self) {
            _ = try ZipArchive(data: Data(repeating: 0, count: 100), url: URL(fileURLWithPath: "/x"))
        }
    }
}

@Suite struct NaturalSortTests {
    @Test func versionOrder() {
        let names = ["p10.jpg", "p2.jpg", "p1.jpg", "p02.jpg", "p1a.jpg", "p1.png"]
        let sorted = names.sorted(by: NaturalSort.isOrderedBefore)
        #expect(sorted == ["p1.jpg", "p1.png", "p1a.jpg", "p02.jpg", "p2.jpg", "p10.jpg"])
    }
    @Test func mixedPaddingDoesNotScramble() {
        let names = (1...120).map { "\($0).jpg" } + ["005.jpg"]
        let s = names.shuffled().sorted(by: NaturalSort.isOrderedBefore)
        #expect(s.first == "1.jpg"); #expect(s.last == "120.jpg")
        #expect(s.firstIndex(of: "005.jpg")! + 1 == s.firstIndex(of: "5.jpg")!)
    }
}

@Suite struct ComicInfoTests {
    @Test func parsesFixture() throws {
        let z = try ZipArchive(url: fixture("stored.zip"))
        let ci = try ComicInfo.parse(try z.data(for: try #require(z.entry(named: ComicInfo.entryName))))
        #expect(ci.series == "テスト"); #expect(ci.number == "3b"); #expect(ci.volume == 3)
        #expect(ci.rightToLeft); #expect(ci.pageCount == 4)
        #expect(ci.pages.count == 4)
        #expect(ci.pages[0].type == "FrontCover")
        #expect(ci.pages[2].doublePage && ci.pages[2].imageWidth == 16)
        #expect(!ci.pages[1].doublePage)
    }

    @Test(arguments: [
        ("月夜の物語０１.cbz", "月夜の物語", "1"),
        ("月夜の物語１６b.cbz", "月夜の物語", "16b"),
        ("ALPHA×BETA３７.cbz", "ALPHA×BETA", "37"),
        ("そら・うた・ゆめ！ アンソロジーコミック０６.cbz", "そら・うた・ゆめ！ アンソロジーコミック", "6"),
        ("月夜の物語００b.cbz", "月夜の物語", "0b"),
        ("風の旅人 外伝.cbz", "風の旅人", ""),
        ("Series v12.cbz", "Series v", "12"),
    ])
    func filenameFallback(_ file: String, _ series: String, _ number: String) {
        let r = FilenameMetadata.parse(fileName: file, parentFolder: "風の旅人")
        #expect(r.series == series); #expect(r.number == number)
    }
}

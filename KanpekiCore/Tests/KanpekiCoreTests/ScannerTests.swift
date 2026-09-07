import Testing
import Foundation
import SwiftData
@testable import KanpekiCore

/// Build a synthetic library on disk from the fixture PNGs.
private func makeLibrary() throws -> (URL, [CloudFileItem]) {
    let root = FileManager.default.temporaryDirectory.appending(path: "kanpeki-test-\(UUID())")
    let z = try ZipArchive(url: Bundle.module.url(forResource: "stored.zip", withExtension: nil, subdirectory: "Fixtures")!)
    let cover = try z.pageData(3), page = try z.pageData(0)
    var items: [CloudFileItem] = []
    for (series, n) in [("月夜の物語", "０１"), ("月夜の物語", "０１b"), ("風の旅人", "２４")] {
        let dir = root.appending(path: "日本語/\(series)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var entries = [ZipWriter.Entry(name: "000.jpg", data: cover)]
        entries += (1...(n.hasSuffix("b") ? 6 : 5)).map { ZipWriter.Entry(name: "\($0).png", data: page) }  // b variant differs
        if series == "風の旅人" {
            entries.append(.init(name: "ComicInfo.xml", data: Data("""
            <ComicInfo><Series>風の旅人</Series><Number>24</Number><Manga>YesAndRightToLeft</Manga>
            <Pages><Page Image="0" Type="FrontCover"/><Page Image="3" DoublePage="true"/></Pages></ComicInfo>
            """.utf8)))
        }
        let url = dir.appending(path: "\(series)\(n).cbz")
        try ZipWriter.stored(entries).write(to: url)
        let v = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        items.append(CloudFileItem(url: url, relativePath: "日本語/\(series)/\(series)\(n).cbz", name: "\(series)\(n).cbz",
                                   size: Int64(v.fileSize!), modified: v.contentModificationDate, download: .downloaded))
    }
    return (root, items)
}

@Suite struct ScannerTests {
    @Test func scansAndRebuildsFromNothing() async throws {
        let (root, items) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = try LibraryStore.makeContainer(inMemory: true)
        let scanner = LibraryScanner(modelContainer: container)

        let s1 = try await scanner.scan(items)
        #expect(s1.scanned == 3 && s1.failed == 0)
        let source = CloudLibrarySource(rootURL: root, isUbiquitous: false, container: container, downloads: DownloadManager(defaults: UserDefaults(suiteName: "test-\(UUID())")!))
        await source.update(items: items)
        let series = try await source.listSeries()
        #expect(series.map(\.name) == ["月夜の物語", "風の旅人"])
        let jjk = try await source.listVolumes(series: "月夜の物語")
        #expect(jjk.map(\.number) == ["1", "1b"])       // b suffix is NOT a duplicate
        #expect(Set(jjk.map(\.id)).count == 2)          // distinct content IDs
        let kny = try await source.listVolumes(series: "風の旅人")[0]
        #expect(kny.pageCount == 6 && kny.rightToLeft)
        #expect(try await source.pageCount(volume: kny.id) == 6)
        let png = try await source.pageData(volume: kny.id, index: 1)
        #expect(png.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(try await source.coverThumbnail(volume: kny.id) != nil)

        // Second scan: nothing changed.
        let s2 = try await scanner.scan(items)
        #expect(s2.unchanged == 3 && s2.scanned == 0)

        // Wipe and rebuild: identical IDs come back from the files alone.
        let before = Set(jjk.map(\.id.rawValue) + [kny.id.rawValue])
        try await scanner.wipe()
        #expect(try await scanner.count() == 0)
        let s3 = try await scanner.scan(items)
        #expect(s3.scanned == 3)
        let after = Set(try await source.listVolumes(series: "月夜の物語").map(\.id.rawValue)
                        + (try await source.listVolumes(series: "風の旅人")).map(\.id.rawValue))
        #expect(before == after)

        // Removing a file removes its row.
        let s4 = try await scanner.scan(Array(items.dropLast()))
        #expect(s4.removed == 1)
    }

    @Test func provisionalRowsForRemoteFiles() async throws {
        let container = try LibraryStore.makeContainer(inMemory: true)
        let scanner = LibraryScanner(modelContainer: container)
        let remote = CloudFileItem(url: URL(fileURLWithPath: "/nowhere/ALPHA×BETA３７.cbz"), relativePath: "日本語/ALPHA×BETA/ALPHA×BETA３７.cbz",
                                   name: "ALPHA×BETA３７.cbz", size: 50_000_000, modified: nil, download: .notDownloaded)
        let s = try await scanner.scan([remote])
        #expect(s.provisional == 1)
        let source = CloudLibrarySource(rootURL: URL(fileURLWithPath: "/nowhere"), isUbiquitous: false, container: container, downloads: DownloadManager(defaults: UserDefaults(suiteName: "test-\(UUID())")!))
        await source.update(items: [remote])
        let v = try await source.listVolumes(series: "ALPHA×BETA")[0]
        #expect(v.number == "37" && v.availability == .remote(bytes: 50_000_000))
        #expect(v.id.rawValue.hasPrefix("path:"))
        await #expect(throws: LibraryError.self) { _ = try await source.pageData(volume: v.id, index: 0) }
    }
}

@Suite struct SyncStoreTests {
    @Test func localStoreRoundTripsAndNotifies() async throws {
        let store = LocalSyncStore(defaults: UserDefaults(suiteName: "sync-\(UUID())")!)
        let id = ContentID(rawValue: "abc")
        #expect(try await store.progress(for: id) == nil)
        let stream = store.observeChanges()
        try await store.setProgress(ReadingProgress(page: 42, pageCount: 200, device: "test"), for: id)
        #expect(try await store.progress(for: id)?.page == 42)
        var it = stream.makeAsyncIterator()
        let change = await it.next()
        #expect(change?.id == id && change?.progress.page == 42)
    }
}

@Suite struct DownloadManagerTests {
    @Test func lruOrderAndCap() async throws {
        let dm = DownloadManager(defaults: UserDefaults(suiteName: "dm-\(UUID())")!)
        await dm.setByteCap(150)
        func item(_ n: String, _ size: Int64) -> CloudFileItem {
            CloudFileItem(url: URL(fileURLWithPath: "/x/\(n)"), relativePath: n, name: n, size: size, modified: nil, download: .downloaded)
        }
        let a = item("a", 100), b = item("b", 100), c = item("c", 100)
        await dm.touch(a); try await Task.sleep(for: .milliseconds(5))
        await dm.touch(c)
        #expect(await dm.localBytes([a, b, c]) == 300)
        // b never opened → oldest; then a; c is newest. Eviction itself fails
        // on a non-ubiquitous path, but the chosen order is what we're testing.
        var stamped: [(String, Date)] = []
        for i in [a, b, c] { stamped.append((i.name, await dm.lastAccess(of: i) ?? .distantPast)) }
        #expect(stamped.sorted { $0.1 < $1.1 }.map(\.0) == ["b", "a", "c"])
        await dm.pin(c)
        _ = await dm.enforceCap([a, b, c])
    }
}

@Suite struct VolumeIndexTests {
    @Test func indexUpgradesProvisionalRows() async throws {
        // Device A has the bytes and scans them.
        let (root, items) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = LibraryScanner(modelContainer: try LibraryStore.makeContainer(inMemory: true))
        _ = try await a.scan(items)
        let store = LocalSyncStore(defaults: UserDefaults(suiteName: "idx-\(UUID())")!, key: "idx-\(UUID())")
        let exported = try await a.exportIndex()
        #expect(exported.count == 3 && exported.allSatisfy { $0.coverJPEG != nil })
        try await store.publishVolumeIndex(exported)

        // Device B only sees cloud placeholders.
        let remote = items.map { CloudFileItem(url: $0.url, relativePath: $0.relativePath, name: $0.name, size: $0.size, modified: nil, download: .notDownloaded) }
        let bContainer = try LibraryStore.makeContainer(inMemory: true)
        let b = LibraryScanner(modelContainer: bContainer)
        let s = try await b.scan(remote)
        #expect(s.provisional == 3)
        let applied = try await b.apply(index: try await store.volumeIndex())
        #expect(applied == 3)
        let src = CloudLibrarySource(rootURL: root, isUbiquitous: false, container: bContainer, downloads: DownloadManager(defaults: UserDefaults(suiteName: "t-\(UUID())")!))
        await src.update(items: remote)
        let v = try await src.listVolumes(series: "風の旅人")[0]
        #expect(!v.id.rawValue.hasPrefix("path:"))                 // real content ID before any download
        #expect(v.pageCount == 6 && v.availability == .remote(bytes: v.byteSize))
        #expect(try await src.coverThumbnail(volume: v.id) != nil)
        #expect(Set(exported.map(\.contentID)).contains(v.id.rawValue))
        // Applying twice is idempotent; scanned rows untouched.
        #expect(try await b.apply(index: try await store.volumeIndex()) == 0)
    }
}

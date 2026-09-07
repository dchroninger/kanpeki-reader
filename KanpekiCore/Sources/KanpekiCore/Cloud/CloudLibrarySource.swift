import Foundation
import SwiftData
import os

/// `LibrarySource` over the iCloud container (or a plain folder). Answers
/// listing questions from the SwiftData cache and page questions from
/// `ZipArchive`, downloading on demand through `DownloadManager`.
public actor CloudLibrarySource: LibrarySource {
    public let rootURL: URL
    public let isUbiquitous: Bool
    public let downloads: DownloadManager
    private let container: ModelContainer
    private var items: [String: CloudFileItem] = [:]
    private var open: [(id: ContentID, item: CloudFileItem, zip: ZipArchive)] = []
    private let maxOpen = 3
    private let changeStream = Broadcaster<Void>()
    private let log = Logger(subsystem: "com.dchroninger.kanpeki", category: "source")

    public init(rootURL: URL, isUbiquitous: Bool, container: ModelContainer, downloads: DownloadManager) {
        self.rootURL = rootURL; self.isUbiquitous = isUbiquitous
        self.container = container; self.downloads = downloads
    }

    /// The monitor feeds snapshots here; the app wires the two together.
    public func update(items new: [CloudFileItem]) {
        items = Dictionary(uniqueKeysWithValues: new.map { ($0.relativePath, $0) })
        changeStream.send(())
    }

    public nonisolated var changes: AsyncStream<Void> { changeStream.stream() }

    // MARK: LibrarySource

    public func listSeries() async throws -> [SeriesRef] {
        let ctx = ModelContext(container)
        let recs = try ctx.fetch(FetchDescriptor<VolumeRecord>())
        let grouped = Dictionary(grouping: recs, by: \.series)
        return grouped.map { SeriesRef(name: $0.key, volumeCount: $0.value.count) }
            .sorted { NaturalSort.isOrderedBefore($0.name, $1.name) }
    }

    public func listVolumes(series: String) async throws -> [VolumeRef] {
        let ctx = ModelContext(container)
        let recs = try ctx.fetch(FetchDescriptor<VolumeRecord>(predicate: #Predicate { $0.series == series }))
        // Byte-identical files share a ContentID (same content, same place);
        // show one row for them. Real "b" variants differ and stay distinct.
        var seen = Set<ContentID>()
        return recs.map { ref(for: $0) }.filter { seen.insert($0.id).inserted }
            .sorted { NaturalSort.isOrderedBefore($0.number, $1.number) }
    }

    public func pageCount(volume: ContentID) async throws -> Int {
        try record(for: volume).pageCount
    }

    public func prepare(volume: ContentID) async throws {
        let (item, _) = try locate(volume)
        try await downloads.ensureLocal(item, isUbiquitous: isUbiquitous)
        _ = try archive(for: volume)
    }

    public func pageData(volume: ContentID, index: Int) async throws -> Data {
        let zip = try archive(for: volume)
        return try zip.pageData(index)
    }

    // MARK: Extras the app uses (still no cloud types leak)

    public func ref(for volume: ContentID) throws -> VolumeRef { ref(for: try record(for: volume)) }

    public func coverThumbnail(volume: ContentID) throws -> Data? { try record(for: volume).coverThumbnail }

    public func item(for volume: ContentID) throws -> CloudFileItem { try locate(volume).0 }

    public func allItems() -> [CloudFileItem] { Array(items.values) }

    public func release(volume: ContentID) async {
        if let i = open.firstIndex(where: { $0.id == volume }) {
            let e = open.remove(at: i)
            await downloads.unpin(e.item)
        }
    }

    /// Provisional rows (not yet downloaded) are keyed by path until scanned.
    public static func provisionalID(_ path: String) -> ContentID { ContentID(rawValue: "path:" + path) }

    // MARK: Internals

    private func ref(for r: VolumeRecord) -> VolumeRef {
        let id = r.contentID.map(ContentID.init(rawValue:)) ?? Self.provisionalID(r.relativePath)
        let item = items[r.relativePath]
        let avail: Availability = switch item?.download {
        case .downloaded: .local
        case .notDownloaded: .remote(bytes: r.fileSize)
        case .downloading(let f): .downloading(fraction: f)
        case nil: .unknown
        }
        return VolumeRef(id: id, series: r.series, number: r.number, title: r.title, pageCount: r.pageCount,
                         rightToLeft: r.rightToLeft, byteSize: r.fileSize, availability: avail)
    }

    private func record(for id: ContentID) throws -> VolumeRecord {
        let ctx = ModelContext(container)
        if id.rawValue.hasPrefix("path:") {
            let p = String(id.rawValue.dropFirst(5))
            if let r = try ctx.fetch(FetchDescriptor<VolumeRecord>(predicate: #Predicate { $0.relativePath == p })).first { return r }
        } else {
            let raw = id.rawValue
            if let r = try ctx.fetch(FetchDescriptor<VolumeRecord>(predicate: #Predicate { $0.contentID == raw })).first { return r }
        }
        throw LibraryError.unknownVolume(id)
    }

    private func locate(_ id: ContentID) throws -> (CloudFileItem, VolumeRecord) {
        let r = try record(for: id)
        guard let item = items[r.relativePath] else { throw LibraryError.unknownVolume(id) }
        return (item, r)
    }

    private func archive(for id: ContentID) throws -> ZipArchive {
        if let i = open.firstIndex(where: { $0.id == id }) {
            let e = open.remove(at: i); open.append(e); return e.zip
        }
        let (item, _) = try locate(id)
        guard item.isLocal else { throw LibraryError.notAvailable(id) }
        let zip = try LibraryScanner.openCoordinated(item.url)
        open.append((id, item, zip))
        Task { await downloads.pin(item) }
        while open.count > maxOpen {
            let e = open.removeFirst()
            Task { await downloads.unpin(e.item) }
        }
        return zip
    }
}

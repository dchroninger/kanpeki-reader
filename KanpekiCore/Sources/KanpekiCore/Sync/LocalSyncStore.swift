import Foundation

/// UserDefaults-backed store. Used in tests, previews, and as the fallback
/// when no iCloud account is available (the UI says so).
public actor LocalSyncStore: SyncStore {
    private let defaults: UserDefaults
    private let key: String
    private var map: [String: ReadingProgress]
    private let changes = Broadcaster<SyncChange>()

    public init(defaults: UserDefaults = .standard, key: String = "KanpekiLocalProgress") {
        self.defaults = defaults; self.key = key
        if let d = defaults.data(forKey: key), let m = try? JSONDecoder().decode([String: ReadingProgress].self, from: d) {
            map = m
        } else { map = [:] }
    }

    public func progress(for id: ContentID) async throws -> ReadingProgress? { map[id.rawValue] }

    public func setProgress(_ p: ReadingProgress, for id: ContentID) async throws {
        map[id.rawValue] = p
        if let d = try? JSONEncoder().encode(map) { defaults.set(d, forKey: key) }
        changes.send(SyncChange(id: id, progress: p))
    }

    public func allProgress() async throws -> [ContentID: ReadingProgress] {
        Dictionary(uniqueKeysWithValues: map.map { (ContentID(rawValue: $0.key), $0.value) })
    }

    public func refresh() async throws {}

    // MARK: Volume index (JSON file next to the app's data)

    private var indexURL: URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return dir.appending(path: "Kanpeki-\(key)-index.json")
    }

    public func publishVolumeIndex(_ entries: [VolumeIndexEntry]) async throws {
        var idx = try await volumeIndex()
        for e in entries { idx[e.relativePath] = e }
        try JSONEncoder().encode(idx).write(to: indexURL, options: .atomic)
    }

    public func volumeIndex() async throws -> [String: VolumeIndexEntry] {
        guard let d = try? Data(contentsOf: indexURL) else { return [:] }
        return (try? JSONDecoder().decode([String: VolumeIndexEntry].self, from: d)) ?? [:]
    }

    public nonisolated func observeChanges() -> AsyncStream<SyncChange> { changes.stream() }
}

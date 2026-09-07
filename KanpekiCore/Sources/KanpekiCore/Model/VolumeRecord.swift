import Foundation
import SwiftData

/// Derived cache row. Local-only store; anything here can be rebuilt by
/// rescanning the files. Keyed by relative path (a file identity), carrying
/// the content-derived `ContentID` once the bytes have been seen.
@Model
public final class VolumeRecord {
    @Attribute(.unique) public var relativePath: String
    /// nil until the archive has been downloaded and scanned. Never used as a
    /// sync key while nil — a not-yet-downloaded file has no content to hash.
    public var contentID: String?
    public var series: String
    public var number: String
    public var title: String
    public var pageCount: Int
    public var pageNames: [String]
    public var doublePages: [Int]
    public var rightToLeft: Bool
    public var hasComicInfo: Bool
    public var fileSize: Int64
    public var modified: Date?
    public var scannedAt: Date?
    @Attribute(.externalStorage) public var coverThumbnail: Data?

    public init(relativePath: String, series: String, number: String, title: String, fileSize: Int64, modified: Date?) {
        self.relativePath = relativePath
        self.series = series; self.number = number; self.title = title
        self.pageCount = 0; self.pageNames = []; self.doublePages = []
        self.rightToLeft = true; self.hasComicInfo = false
        self.fileSize = fileSize; self.modified = modified
    }

    public var isScanned: Bool { contentID != nil }
}

public enum LibraryStore {
    /// Local-only container under Application Support. `cloudKitDatabase: .none`
    /// is deliberate: this is a cache, not state.
    public static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema([VolumeRecord.self])
        let config: ModelConfiguration
        if inMemory {
            config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        } else {
            let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appending(path: "Kanpeki", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            config = ModelConfiguration(schema: schema, url: dir.appending(path: "library.store"), cloudKitDatabase: .none)
        }
        return try ModelContainer(for: schema, configurations: [config])
    }
}

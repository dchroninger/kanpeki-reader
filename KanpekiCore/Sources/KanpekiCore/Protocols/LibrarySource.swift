import Foundation

/// Content-derived identity of a volume. Hash of the ZIP central directory —
/// never the file URL, so a rename or move keeps the reader's place.
public struct ContentID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

public struct SeriesRef: Hashable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let volumeCount: Int
    public init(name: String, volumeCount: Int) { self.name = name; self.volumeCount = volumeCount }
}

/// Whether a volume's bytes are readable right now. The renderer only needs
/// to know "can I read pages", not "where are they".
public enum Availability: Hashable, Sendable {
    case local
    case remote(bytes: Int64)
    case downloading(fraction: Double)
    case unknown
}

public struct VolumeRef: Hashable, Sendable, Identifiable {
    public var id: ContentID
    public let series: String
    /// Display number — string because "16b" and "外伝" are real.
    public let number: String
    public let title: String
    public let pageCount: Int
    public let rightToLeft: Bool
    public let byteSize: Int64
    public var availability: Availability
    /// The user asked for this one to stay on the device (flight mode).
    public var keptOffline: Bool

    public init(id: ContentID, series: String, number: String, title: String, pageCount: Int,
                rightToLeft: Bool, byteSize: Int64, availability: Availability, keptOffline: Bool = false) {
        self.id = id; self.series = series; self.number = number; self.title = title
        self.pageCount = pageCount; self.rightToLeft = rightToLeft
        self.byteSize = byteSize; self.availability = availability; self.keptOffline = keptOffline
    }
}

/// Where archives come from. The renderer must never learn the answer.
///
/// Phase 1: `CloudLibrarySource`. Phase 3: `OPDSLibrarySource`.
public protocol LibrarySource: Sendable {
    func listSeries() async throws -> [SeriesRef]
    func listVolumes(series: String) async throws -> [VolumeRef]
    func pageCount(volume: ContentID) async throws -> Int
    /// Raw encoded image bytes for one page. Decoding is the renderer's job.
    func pageData(volume: ContentID, index: Int) async throws -> Data
    /// Make `pageData` possible (for a cloud source: download). Progress
    /// surfaces through `listVolumes`/`changes`; this just awaits readiness.
    func prepare(volume: ContentID) async throws
    /// Fires whenever a re-list could return something different.
    var changes: AsyncStream<Void> { get }
}

public enum LibraryError: Error, Sendable, LocalizedError {
    case unknownVolume(ContentID)
    case pageOutOfRange(Int)
    case notAvailable(ContentID)
    case containerUnavailable

    public var errorDescription: String? {
        switch self {
        case .unknownVolume(let id): "Unknown volume \(id)"
        case .pageOutOfRange(let i): "Page \(i) out of range"
        case .notAvailable(let id): "Volume \(id) not downloaded"
        case .containerUnavailable: "iCloud container unavailable — sign in to iCloud and enable iCloud Drive"
        }
    }
}

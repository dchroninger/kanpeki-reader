import Foundation

/// What one device derived from an archive it holds, published so devices
/// that only see the file as a cloud placeholder can show a real library.
/// Derived data — a cache shared through the sync store, never the truth.
public struct VolumeIndexEntry: Hashable, Codable, Sendable, Identifiable {
    public var id: String { relativePath }
    public var relativePath: String
    public var contentID: String
    public var series: String
    public var number: String
    public var title: String
    public var pageCount: Int
    public var rightToLeft: Bool
    public var fileSize: Int64
    public var coverJPEG: Data?
    public var updatedAt: Date

    public init(relativePath: String, contentID: String, series: String, number: String, title: String,
                pageCount: Int, rightToLeft: Bool, fileSize: Int64, coverJPEG: Data?, updatedAt: Date = .now) {
        self.relativePath = relativePath; self.contentID = contentID; self.series = series; self.number = number
        self.title = title; self.pageCount = pageCount; self.rightToLeft = rightToLeft; self.fileSize = fileSize
        self.coverJPEG = coverJPEG; self.updatedAt = updatedAt
    }
}

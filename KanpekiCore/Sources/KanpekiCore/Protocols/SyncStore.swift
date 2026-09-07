import Foundation

public struct ReadingProgress: Hashable, Codable, Sendable {
    public var page: Int
    public var pageCount: Int
    public var updatedAt: Date
    /// Human-readable device name, for "last read on iPhone" UI. Never leaves
    /// the user's private database.
    public var device: String

    public init(page: Int, pageCount: Int, updatedAt: Date = .now, device: String) {
        self.page = page; self.pageCount = pageCount; self.updatedAt = updatedAt; self.device = device
    }
}

public struct SyncChange: Hashable, Sendable {
    public let id: ContentID
    public let progress: ReadingProgress
    public init(id: ContentID, progress: ReadingProgress) { self.id = id; self.progress = progress }
}

/// Where reading state lives. `CloudKitSyncStore` in Phase 1.
///
/// CloudKit types must not appear outside its implementation. If a second
/// platform ever happens, this protocol is the seam.
public protocol SyncStore: Sendable {
    func progress(for id: ContentID) async throws -> ReadingProgress?
    func setProgress(_ progress: ReadingProgress, for id: ContentID) async throws
    func allProgress() async throws -> [ContentID: ReadingProgress]
    /// Pull remote changes now. Emits into `observeChanges()`.
    func refresh() async throws
    func observeChanges() -> AsyncStream<SyncChange>

    /// Library index: derived metadata + cover per archive, keyed by
    /// relative path. Published by whichever device has the bytes.
    func publishVolumeIndex(_ entries: [VolumeIndexEntry]) async throws
    func volumeIndex() async throws -> [String: VolumeIndexEntry]
}

import Foundation

/// One archive as seen by the folder monitor. Pure value; no Foundation
/// ubiquity types escape past here.
public struct CloudFileItem: Hashable, Sendable, Identifiable {
    public enum DownloadState: Hashable, Sendable {
        case downloaded
        case notDownloaded
        case downloading(fraction: Double)
    }

    public var id: String { relativePath }
    public let url: URL
    /// Path relative to the library root, e.g. `日本語/月夜の物語/月夜の物語０１.cbz`.
    public let relativePath: String
    public let name: String
    public let size: Int64
    public let modified: Date?
    public let download: DownloadState
    public let isUploaded: Bool
    public let uploadFraction: Double?
    public let error: String?

    public init(url: URL, relativePath: String, name: String, size: Int64, modified: Date?,
                download: DownloadState, isUploaded: Bool = true, uploadFraction: Double? = nil, error: String? = nil) {
        self.url = url; self.relativePath = relativePath; self.name = name; self.size = size
        self.modified = modified; self.download = download; self.isUploaded = isUploaded
        self.uploadFraction = uploadFraction; self.error = error
    }

    public var isLocal: Bool { download == .downloaded }
    public var parentFolder: String? {
        let comps = relativePath.split(separator: "/")
        return comps.count >= 2 ? String(comps[comps.count - 2]) : nil
    }
}

/// Watches a library root and reports the `.cbz` files in it.
@MainActor
public protocol LibraryFolderMonitor: AnyObject {
    var rootURL: URL { get }
    var items: [CloudFileItem] { get }
    var isGathering: Bool { get }
    var updates: AsyncStream<[CloudFileItem]> { get }
    func start()
    func stop()
    func refresh()
}

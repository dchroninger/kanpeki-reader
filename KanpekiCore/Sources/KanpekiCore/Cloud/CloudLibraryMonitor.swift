import Foundation
import Observation

/// `NSMetadataQuery` over the ubiquity container's Documents scope.
/// Emits a full snapshot on every change (download progress included).
@MainActor
@Observable
public final class CloudLibraryMonitor: LibraryFolderMonitor {
    public let rootURL: URL
    public private(set) var items: [CloudFileItem] = []
    public private(set) var isGathering = false

    private let query = NSMetadataQuery()
    private var observers: [any NSObjectProtocol] = []
    private let bus = Broadcaster<[CloudFileItem]>()

    public init(rootURL: URL) {
        self.rootURL = rootURL
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K LIKE[c] '*.cbz'", NSMetadataItemFSNameKey)
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemPathKey, ascending: true)]
        query.notificationBatchingInterval = 0.25
    }

    /// Replays the current snapshot, then live changes. Subscribing and
    /// sending both happen on the main actor, so nothing slips between.
    public var updates: AsyncStream<[CloudFileItem]> { bus.stream(replaying: items) }

    public func start() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        for name in [NSNotification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observers.append(nc.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.snapshot() }
            })
        }
        isGathering = true
        query.start()
    }

    public func stop() {
        query.stop()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    public func refresh() { snapshot() }

    private func snapshot() {
        query.disableUpdates()
        defer { query.enableUpdates() }
        isGathering = false
        let root = rootURL.standardizedFileURL.path
        var out: [CloudFileItem] = []
        for case let item as NSMetadataItem in query.results {
            guard let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL else { continue }
            let p = url.standardizedFileURL.path
            let rel = p.hasPrefix(root) ? String(p.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) : url.lastPathComponent
            let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
            let downloading = item.value(forAttribute: NSMetadataUbiquitousItemIsDownloadingKey) as? Bool ?? false
            let pct = item.value(forAttribute: NSMetadataUbiquitousItemPercentDownloadedKey) as? Double
            let state: CloudFileItem.DownloadState
            if status == NSMetadataUbiquitousItemDownloadingStatusCurrent || status == NSMetadataUbiquitousItemDownloadingStatusDownloaded {
                state = .downloaded
            } else if downloading {
                state = .downloading(fraction: (pct ?? 0) / 100)
            } else {
                state = .notDownloaded
            }
            let err = (item.value(forAttribute: NSMetadataUbiquitousItemDownloadingErrorKey) as? NSError)?.localizedDescription
                ?? (item.value(forAttribute: NSMetadataUbiquitousItemUploadingErrorKey) as? NSError)?.localizedDescription
            out.append(CloudFileItem(
                url: url, relativePath: rel,
                name: item.value(forAttribute: NSMetadataItemFSNameKey) as? String ?? url.lastPathComponent,
                size: (item.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.int64Value ?? 0,
                modified: item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date,
                download: state,
                isUploaded: item.value(forAttribute: NSMetadataUbiquitousItemIsUploadedKey) as? Bool ?? true,
                uploadFraction: (item.value(forAttribute: NSMetadataUbiquitousItemIsUploadingKey) as? Bool ?? false)
                    ? ((item.value(forAttribute: NSMetadataUbiquitousItemPercentUploadedKey) as? Double) ?? 0) / 100 : nil,
                error: err))
        }
        out.sort { NaturalSort.isOrderedBefore($0.relativePath, $1.relativePath) }
        if out != items {
            items = out
            bus.send(out)
        }
    }
}

/// Plain-folder monitor for simulators / machines without iCloud. Same shape,
/// everything reports as downloaded. Polls; good enough for a fallback.
@MainActor
@Observable
public final class LocalFolderMonitor: LibraryFolderMonitor {
    public let rootURL: URL
    public private(set) var items: [CloudFileItem] = []
    public private(set) var isGathering = false
    private var timer: Timer?
    private let bus = Broadcaster<[CloudFileItem]>()

    public init(rootURL: URL) { self.rootURL = rootURL }

    /// Replays the current snapshot, then live changes. Subscribing and
    /// sending both happen on the main actor, so nothing slips between.
    public var updates: AsyncStream<[CloudFileItem]> { bus.stream(replaying: items) }

    public func start() {
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }
    public func stop() { timer?.invalidate(); timer = nil }

    public func refresh() {
        let root = rootURL.standardizedFileURL
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        var out: [CloudFileItem] = []
        if let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
            for case let u as URL in e where u.pathExtension.lowercased() == "cbz" {
                let v = try? u.resourceValues(forKeys: Set(keys))
                guard v?.isRegularFile == true else { continue }
                let rel = String(u.standardizedFileURL.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                out.append(CloudFileItem(url: u, relativePath: rel, name: u.lastPathComponent,
                                         size: Int64(v?.fileSize ?? 0), modified: v?.contentModificationDate, download: .downloaded))
            }
        }
        out.sort { NaturalSort.isOrderedBefore($0.relativePath, $1.relativePath) }
        if out != items {
            items = out
            bus.send(out)
        }
    }
}

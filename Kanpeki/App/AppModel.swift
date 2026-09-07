import SwiftUI
import SwiftData
import KanpekiCore
import os

/// Wires container → monitor → scanner → source → views, and sync store →
/// views. Views only ever see `LibrarySource` / `SyncStore` values.
@MainActor
@Observable
final class AppModel {
    enum Backend: Equatable {
        case iCloud(URL), localFolder(URL)
        var rootURL: URL { switch self { case .iCloud(let u), .localFolder(let u): u } }
        var isCloud: Bool { if case .iCloud = self { true } else { false } }
        var label: String { isCloud ? "iCloud Drive" : "Local folder (iCloud unavailable)" }
    }

    private(set) var backend: Backend?
    private(set) var monitor: (any LibraryFolderMonitor)?
    private(set) var source: CloudLibrarySource?
    private(set) var sync: any SyncStore = LocalSyncStore()
    private(set) var cloudSync: CloudKitSyncStore?
    private(set) var accountState = "checking…"
    private(set) var series: [SeriesRef] = []
    private(set) var volumes: [String: [VolumeRef]] = [:]
    private(set) var progress: [ContentID: ReadingProgress] = [:]
    private(set) var items: [CloudFileItem] = []
    private(set) var scanSummary: ScanSummary?
    private(set) var scanProgress: (done: Int, total: Int)?
    private(set) var localBytes: Int64 = 0
    var byteCap: Int64 = DownloadManager.defaultCap { didSet { Task { await downloads.setByteCap(byteCap); await enforceCap() } } }
    private(set) var evictions: [String] = []
    private(set) var syncError: String?
    private(set) var lastSync: Date?
    private(set) var startupError: String?
    var isScanning: Bool { scanProgress != nil }

    let container: ModelContainer
    let scanner: LibraryScanner
    let downloads = DownloadManager()
    private let log = Logger(subsystem: "com.dchroninger.kanpeki", category: "app")
    private var scanTask: Task<Void, Never>?

    init() {
        do { container = try LibraryStore.makeContainer() }
        catch { fatalError("SwiftData store: \(error)") }
        scanner = LibraryScanner(modelContainer: container)
    }

    func start() async {
        guard backend == nil else { return }
        byteCap = await downloads.byteCap
        // 1. Bulk: ubiquity container, else app Documents.
        if let info = await UbiquityContainer.resolve() {
            backend = .iCloud(info.documentsURL)
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            backend = .localFolder(docs)
        }
        let root = backend!.rootURL
        let mon: any LibraryFolderMonitor = backend!.isCloud ? CloudLibraryMonitor(rootURL: root) : LocalFolderMonitor(rootURL: root)
        monitor = mon
        let src = CloudLibrarySource(rootURL: root, isUbiquitous: backend!.isCloud, container: container, downloads: downloads)
        source = src

        // 2. State: CloudKit private DB when an account is there, else local.
        let ck = CloudKitSyncStore()
        let state = await ck.accountState()
        accountState = state.rawValue
        if state == .available { cloudSync = ck; sync = ck } else { sync = LocalSyncStore() }
        Task { [weak self] in
            guard let self else { return }
            for await change in sync.observeChanges() { self.progress[change.id] = change.progress }
        }
        await refreshSync()

        // 3. Folder → source → scanner → lists.
        Task { [weak self] in
            for await snapshot in mon.updates {
                guard let self else { return }
                self.items = snapshot
                await src.update(items: snapshot)
                self.localBytes = await self.downloads.localBytes(snapshot)
                self.scheduleScan(snapshot)
            }
        }
        mon.start()
        await refreshLists()
    }

    private func scheduleScan(_ snapshot: [CloudFileItem]) {
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            await self.rescan(snapshot)
        }
    }

    func rescan(_ snapshot: [CloudFileItem]? = nil) async {
        let snap = snapshot ?? items
        scanProgress = (0, snap.count)
        do {
            let summary = try await scanner.scan(snap) { done, total in
                Task { @MainActor [weak self] in self?.scanProgress = (done, total) }
            }
            scanSummary = summary
        } catch { startupError = "Scan failed: \(error.localizedDescription)" }
        scanProgress = nil
        await refreshLists()
        await enforceCap()
    }

    func refreshLists() async {
        guard let source else { return }
        do {
            let s = try await source.listSeries()
            var v: [String: [VolumeRef]] = [:]
            for sr in s { v[sr.name] = try await source.listVolumes(series: sr.name) }
            series = s; volumes = v
        } catch { startupError = error.localizedDescription }
    }

    /// Prove the cache is a cache: drop everything and rebuild from the files.
    func rebuildCache() async {
        do { try await scanner.wipe() } catch { startupError = error.localizedDescription }
        series = []; volumes = [:]
        await rescan()
    }

    func refreshSync() async {
        do {
            try await sync.refresh()
            progress = try await sync.allProgress()
            lastSync = .now; syncError = nil
        } catch { syncError = error.localizedDescription }
    }

    func setProgress(page: Int, pageCount: Int, for id: ContentID) async {
        let p = ReadingProgress(page: page, pageCount: pageCount, device: DeviceName.current)
        progress[id] = p
        do { try await sync.setProgress(p, for: id); syncError = nil }
        catch { syncError = error.localizedDescription }
    }

    func noteProgress(_ p: ReadingProgress, for id: ContentID) { if progress[id] == nil { progress[id] = p } }

    func startDownload(_ v: VolumeRef) {
        guard let source else { return }
        Task {
            do { try await downloads.startDownload(try await source.item(for: v.id)) }
            catch { startupError = error.localizedDescription }
        }
    }

    func evict(_ v: VolumeRef) {
        guard let source else { return }
        Task {
            do { try await downloads.evict(try await source.item(for: v.id)); evictions = await downloads.evictionLog }
            catch { startupError = error.localizedDescription }
            monitor?.refresh()
        }
    }

    var automaticEvictionSupported: Bool { DownloadManager.automaticEvictionSupported }

    func downloadAll() {
        Task { _ = await downloads.downloadAll(items); monitor?.refresh() }
    }

    func enforceCap() async {
        guard backend?.isCloud == true, DownloadManager.automaticEvictionSupported else { return }
        let evicted = await downloads.enforceCap(items)
        if !evicted.isEmpty { evictions = await downloads.evictionLog; monitor?.refresh() }
    }

    func evictAll() {
        Task {
            for i in items where i.isLocal { try? await downloads.evict(i) }
            evictions = await downloads.evictionLog
            monitor?.refresh()
        }
    }

    func revealInFiles() {
        guard let root = backend?.rootURL else { return }
        #if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting([root])
        #else
        if let u = URL(string: "shareddocuments://" + root.path) { UIApplication.shared.open(u) }
        #endif
    }

    func addSampleVolumes() async {
        guard let root = backend?.rootURL else { return }
        do { try SampleLibrary.write(into: root); monitor?.refresh() }
        catch { startupError = error.localizedDescription }
    }
}

import Foundation
import os

/// On-demand download + LRU eviction under a byte cap. iOS cannot hold the
/// whole library; this is the policy that decides what stays local.
///
/// Access times persist across launches so eviction order survives a
/// relaunch. Open archives are pinned and never evicted (they are mmap'd —
/// evicting under a live mapping is a SIGBUS).
public actor DownloadManager {
    public static let defaultCap: Int64 = 2 * 1024 * 1024 * 1024

    /// Automatic eviction is a phone/tablet policy. A Mac holds the whole
    /// library and iCloud Drive already offers "Optimize Mac Storage";
    /// evicting there once threw 8 GB off a user's disk. Manual eviction
    /// stays available everywhere.
    public static var automaticEvictionSupported: Bool {
        #if os(macOS)
        false
        #else
        true
        #endif
    }

    private let fm = FileManager.default
    private let defaults: UserDefaults
    private var lastAccess: [String: Date]   // relativePath -> last open
    private var pinned: [String: Int] = [:]  // relativePath -> pin count
    /// Volumes the user asked to keep on the device (tap-to-download,
    /// multi-select). Never evicted automatically; cleared by "Remove download".
    private var kept: Set<String>
    private let keptKey = "KanpekiKeptOffline"
    private let log = Logger(subsystem: "com.dchroninger.kanpeki", category: "download")
    private let accessKey = "KanpekiLastAccess"
    private let capKey = "KanpekiLocalByteCap"

    public private(set) var evictionLog: [String] = []

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let d = defaults.data(forKey: accessKey), let m = try? JSONDecoder().decode([String: Date].self, from: d) {
            lastAccess = m
        } else { lastAccess = [:] }
        kept = Set(defaults.stringArray(forKey: keptKey) ?? [])
    }

    public func isKept(_ item: CloudFileItem) -> Bool { kept.contains(item.relativePath) }
    public var keptPaths: Set<String> { kept }

    /// Download and keep. Safe to call on an item that is already local.
    public func keep(_ items: [CloudFileItem]) {
        for i in items {
            kept.insert(i.relativePath)
            if !i.isLocal { try? fm.startDownloadingUbiquitousItem(at: i.url) }
        }
        defaults.set(Array(kept), forKey: keptKey)
    }

    public func unkeep(_ item: CloudFileItem) {
        kept.remove(item.relativePath); defaults.set(Array(kept), forKey: keptKey)
    }

    public var byteCap: Int64 {
        get { defaults.object(forKey: capKey) as? Int64 ?? Self.defaultCap }
    }
    public func setByteCap(_ v: Int64) { defaults.set(v, forKey: capKey) }

    public func touch(_ item: CloudFileItem) {
        lastAccess[item.relativePath] = .now
        persist()
    }

    public func pin(_ item: CloudFileItem) { pinned[item.relativePath, default: 0] += 1 }
    public func unpin(_ item: CloudFileItem) {
        if let n = pinned[item.relativePath] { if n <= 1 { pinned[item.relativePath] = nil } else { pinned[item.relativePath] = n - 1 } }
    }

    /// Kick off a download if needed. Progress is observed through the monitor.
    public func startDownload(_ item: CloudFileItem) throws {
        guard !item.isLocal else { return }
        try fm.startDownloadingUbiquitousItem(at: item.url)
        log.info("startDownloading \(item.name, privacy: .private)")
    }

    /// Fresh answer from the file system, not the monitor's last snapshot.
    /// Foundation caches resource values on a URL, so always read through a
    /// new URL value — polling the same one returns the first answer forever.
    public nonisolated static func isLocalNow(_ url: URL) -> Bool {
        guard let v = try? Self.fresh(url).resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
              let s = v.ubiquitousItemDownloadingStatus else { return true } // non-ubiquitous
        return s == .current || s == .downloaded
    }

    private nonisolated static func fresh(_ url: URL) -> URL {
        var u = URL(fileURLWithPath: url.path)
        u.removeAllCachedResourceValues()
        return u
    }

    /// Await local bytes. Polls resource values; the monitor drives UI.
    public func ensureLocal(_ item: CloudFileItem, isUbiquitous: Bool) async throws {
        touch(item)
        guard isUbiquitous, !Self.isLocalNow(item.url) else { return }
        try fm.startDownloadingUbiquitousItem(at: item.url)
        while true {
            try await Task.sleep(for: .milliseconds(400))
            try Task.checkCancellation()
            let v = try Self.fresh(item.url).resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey, .ubiquitousItemDownloadingErrorKey])
            if let e = v.ubiquitousItemDownloadingError { throw e }
            if v.ubiquitousItemDownloadingStatus == .current || v.ubiquitousItemDownloadingStatus == .downloaded { return }
        }
    }

    /// Kick off downloads for everything not local. Progress via the monitor.
    public func downloadAll(_ items: [CloudFileItem]) -> Int {
        var n = 0
        for i in items where !i.isLocal {
            if (try? fm.startDownloadingUbiquitousItem(at: i.url)) != nil { n += 1 }
        }
        return n
    }

    public func evict(_ item: CloudFileItem) throws {
        guard pinned[item.relativePath] == nil else { return }
        unkeep(item)
        try fm.evictUbiquitousItem(at: item.url)
        evictionLog.append("evicted \(item.name) (\(item.size / 1_048_576) MB)")
        log.info("evicted \(item.name, privacy: .private)")
    }

    /// Bytes currently local across the given items.
    public func localBytes(_ items: [CloudFileItem]) -> Int64 {
        items.filter(\.isLocal).reduce(0) { $0 + $1.size }
    }

    /// Evict least-recently-opened archives until local bytes <= cap.
    /// Never-opened files count as oldest. Pinned files are skipped.
    @discardableResult
    public func enforceCap(_ items: [CloudFileItem]) -> [CloudFileItem] {
        guard Self.automaticEvictionSupported else { return [] }
        let cap = byteCap
        var total = localBytes(items)
        guard total > cap else { return [] }
        let candidates = items.filter { $0.isLocal && pinned[$0.relativePath] == nil && !kept.contains($0.relativePath) }
            .sorted { (lastAccess[$0.relativePath] ?? .distantPast) < (lastAccess[$1.relativePath] ?? .distantPast) }
        var evicted: [CloudFileItem] = []
        for c in candidates where total > cap {
            do { try evict(c); total -= c.size; evicted.append(c) }
            catch { log.error("evict failed: \(error.localizedDescription)") }
        }
        return evicted
    }

    public func lastAccess(of item: CloudFileItem) -> Date? { lastAccess[item.relativePath] }

    private func persist() {
        if let d = try? JSONEncoder().encode(lastAccess) { defaults.set(d, forKey: accessKey) }
    }
}

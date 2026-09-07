import Foundation
import CloudKit
import CryptoKit
import os

/// Reading state in the user's CloudKit **private** database. One record per
/// volume in a custom zone, so `refresh()` is a change-token fetch rather
/// than a query (no schema indexes to deploy, works offline-first).
///
/// Conflict rule: newest `updatedAt` wins. This is the only file that may
/// import CloudKit.
public actor CloudKitSyncStore: SyncStore {
    public static let recordType = "ReadingProgress"
    public static let indexRecordType = "VolumeIndex"
    private var index: [String: VolumeIndexEntry] = [:] { didSet { persist(index, "index") } }
    private let container: CKContainer
    private let db: CKDatabase
    private let zoneID = CKRecordZone.ID(zoneName: "KanpekiProgress", ownerName: CKCurrentUserDefaultName)
    private let defaults: UserDefaults
    private let tokenKey = "KanpekiCKChangeToken"
    private let zoneKey = "KanpekiCKZoneCreated"
    private var cache: [String: ReadingProgress] = [:] { didSet { persist(cache, "positions") } }
    private var dirty: Set<String> = []
    private let changes = Broadcaster<SyncChange>()
    private let log = Logger(subsystem: "com.dchroninger.kanpeki", category: "cloudkit")

    public private(set) var lastError: String?
    public private(set) var lastRefresh: Date?

    public init(containerIdentifier: String = UbiquityContainer.identifier, defaults: UserDefaults = .standard) {
        container = CKContainer(identifier: containerIdentifier)
        db = container.privateCloudDatabase
        self.defaults = defaults
        // Change tokens only replay what changed since last time; what we
        // already pulled must survive a relaunch on disk.
        if let saved: [String: ReadingProgress] = Self.load("positions") {
            cache = saved
        } else {
            cache = [:]
            defaults.removeObject(forKey: tokenKey)   // nothing on disk: replay the zone from the start
        }
        index = Self.load("index") ?? [:]
    }

    private static var stateDir: URL {
        let d = ((try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
                 ?? FileManager.default.temporaryDirectory).appending(path: "Kanpeki/cloudkit", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private nonisolated func persist<T: Encodable & Sendable>(_ v: T, _ name: String) {
        Task.detached(priority: .utility) {
            if let d = try? JSONEncoder().encode(v) { try? d.write(to: Self.stateDir.appending(path: name + ".json"), options: .atomic) }
        }
    }
    private static func load<T: Decodable>(_ name: String) -> T? {
        guard let d = try? Data(contentsOf: stateDir.appending(path: name + ".json")) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }

    public enum AccountState: String, Sendable { case available, noAccount, restricted, couldNotDetermine, temporarilyUnavailable }
    public func accountState() async -> AccountState {
        switch try? await container.accountStatus() {
        case .available: .available
        case .noAccount: .noAccount
        case .restricted: .restricted
        case .temporarilyUnavailable: .temporarilyUnavailable
        default: .couldNotDetermine
        }
    }

    // MARK: SyncStore

    public func progress(for id: ContentID) async throws -> ReadingProgress? {
        if let p = cache[id.rawValue] { return p }
        do {
            let r = try await db.record(for: recordID(id))
            let p = Self.progress(from: r)
            if let p { cache[id.rawValue] = p }
            return p
        } catch let e as CKError where e.code == .unknownItem || e.code == .zoneNotFound {
            return nil
        }
    }

    public func setProgress(_ p: ReadingProgress, for id: ContentID) async throws {
        cache[id.rawValue] = p
        dirty.insert(id.rawValue)
        changes.send(SyncChange(id: id, progress: p))
        try await push(id.rawValue)
    }

    public func allProgress() async throws -> [ContentID: ReadingProgress] {
        Dictionary(uniqueKeysWithValues: cache.map { (ContentID(rawValue: $0.key), $0.value) })
    }

    public func refresh() async throws {
        do {
            try await ensureZone()
            for k in dirty { try? await push(k) }
            try await pull()
            lastRefresh = .now
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    public nonisolated func observeChanges() -> AsyncStream<SyncChange> { changes.stream() }

    // MARK: Volume index

    public func volumeIndex() async throws -> [String: VolumeIndexEntry] { index }

    /// Upserts index records. Covers travel as assets; 50 per request keeps
    /// well under CloudKit's per-operation limits.
    public func publishVolumeIndex(_ entries: [VolumeIndexEntry]) async throws {
        try await ensureZone()
        let todo = entries.filter { index[$0.relativePath]?.contentID != $0.contentID }
        guard !todo.isEmpty else { return }
        let tmp = FileManager.default.temporaryDirectory.appending(path: "kanpeki-covers-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        for chunk in stride(from: 0, to: todo.count, by: 50).map({ Array(todo[$0..<min($0 + 50, todo.count)]) }) {
            var records: [CKRecord] = []
            for e in chunk {
                let r = CKRecord(recordType: Self.indexRecordType, recordID: Self.indexRecordID(e.relativePath, zoneID: zoneID))
                r["path"] = e.relativePath; r["contentID"] = e.contentID; r["series"] = e.series; r["number"] = e.number
                r["title"] = e.title; r["pageCount"] = Int64(e.pageCount); r["rtl"] = Int64(e.rightToLeft ? 1 : 0)
                r["fileSize"] = e.fileSize; r["updatedAt"] = e.updatedAt
                if let jpg = e.coverJPEG {
                    let f = tmp.appending(path: UUID().uuidString + ".jpg")
                    try jpg.write(to: f)
                    r["cover"] = CKAsset(fileURL: f)
                }
                records.append(r)
            }
            let result = try await db.modifyRecords(saving: records, deleting: [], savePolicy: .allKeys)
            for (id, res) in result.saveResults {
                if case .success = res, let e = chunk.first(where: { Self.indexRecordID($0.relativePath, zoneID: zoneID) == id }) {
                    index[e.relativePath] = e
                }
            }
        }
    }

    private static func indexRecordID(_ path: String, zoneID: CKRecordZone.ID) -> CKRecord.ID {
        let digest = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return CKRecord.ID(recordName: "idx-" + digest, zoneID: zoneID)
    }

    private static func indexEntry(from r: CKRecord) -> VolumeIndexEntry? {
        guard let path = r["path"] as? String, let cid = r["contentID"] as? String else { return nil }
        var cover: Data? = nil
        if let a = r["cover"] as? CKAsset, let u = a.fileURL { cover = try? Data(contentsOf: u) }
        return VolumeIndexEntry(relativePath: path, contentID: cid, series: r["series"] as? String ?? "",
                                number: r["number"] as? String ?? "", title: r["title"] as? String ?? "",
                                pageCount: Int(r["pageCount"] as? Int64 ?? 0), rightToLeft: (r["rtl"] as? Int64 ?? 1) == 1,
                                fileSize: r["fileSize"] as? Int64 ?? 0, coverJPEG: cover,
                                updatedAt: r["updatedAt"] as? Date ?? .distantPast)
    }

    // MARK: Internals

    private func recordID(_ id: ContentID) -> CKRecord.ID { CKRecord.ID(recordName: id.rawValue, zoneID: zoneID) }

    private func ensureZone() async throws {
        guard !defaults.bool(forKey: zoneKey) else { return }
        _ = try await db.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
        defaults.set(true, forKey: zoneKey)
    }

    private func push(_ key: String) async throws {
        guard let p = cache[key] else { return }
        try await ensureZone()
        let rid = CKRecord.ID(recordName: key, zoneID: zoneID)
        var record: CKRecord
        do { record = try await db.record(for: rid) }
        catch let e as CKError where e.code == .unknownItem { record = CKRecord(recordType: Self.recordType, recordID: rid) }
        // Newest wins: never clobber a newer position from another device.
        if let server = Self.progress(from: record), server.updatedAt > p.updatedAt {
            cache[key] = server; dirty.remove(key)
            changes.send(SyncChange(id: ContentID(rawValue: key), progress: server))
            return
        }
        Self.apply(p, to: record)
        do {
            _ = try await db.modifyRecords(saving: [record], deleting: [], savePolicy: .changedKeys)
            dirty.remove(key)
        } catch let e as CKError where e.code == .serverRecordChanged {
            if let server = e.serverRecord {
                if let sp = Self.progress(from: server), sp.updatedAt > p.updatedAt {
                    cache[key] = sp; dirty.remove(key)
                    changes.send(SyncChange(id: ContentID(rawValue: key), progress: sp))
                } else {
                    Self.apply(p, to: server)
                    _ = try await db.modifyRecords(saving: [server], deleting: [], savePolicy: .changedKeys)
                    dirty.remove(key)
                }
            }
        }
    }

    private func pull() async throws {
        var token = loadToken()
        while true {
            do {
                let r = try await db.recordZoneChanges(inZoneWith: zoneID, since: token)
                for (id, result) in r.modificationResultsByID {
                    guard case .success(let m) = result else { continue }
                    if m.record.recordType == Self.indexRecordType {
                        if let e = Self.indexEntry(from: m.record) { index[e.relativePath] = e }
                        continue
                    }
                    guard let p = Self.progress(from: m.record) else { continue }
                    let key = id.recordName
                    if dirty.contains(key), let local = cache[key], local.updatedAt >= p.updatedAt { continue }
                    if cache[key] != p {
                        cache[key] = p
                        changes.send(SyncChange(id: ContentID(rawValue: key), progress: p))
                    }
                }
                for d in r.deletions {
                    cache[d.recordID.recordName] = nil
                    if d.recordID.recordName.hasPrefix("idx-") { index = index.filter { Self.indexRecordID($0.key, zoneID: zoneID) != d.recordID } }
                }
                token = r.changeToken
                saveToken(token)
                if !r.moreComing { return }
            } catch let e as CKError where e.code == .changeTokenExpired {
                token = nil; saveToken(nil)
            } catch let e as CKError where e.code == .zoneNotFound || e.code == .userDeletedZone {
                defaults.set(false, forKey: zoneKey); saveToken(nil)
                try await ensureZone()
                token = nil
            }
        }
    }

    private static func progress(from r: CKRecord) -> ReadingProgress? {
        guard let page = r["page"] as? Int64, let count = r["pageCount"] as? Int64, let at = r["updatedAt"] as? Date else { return nil }
        return ReadingProgress(page: Int(page), pageCount: Int(count), updatedAt: at, device: r["device"] as? String ?? "?")
    }
    private static func apply(_ p: ReadingProgress, to r: CKRecord) {
        r["page"] = Int64(p.page); r["pageCount"] = Int64(p.pageCount); r["updatedAt"] = p.updatedAt; r["device"] = p.device
    }
    private func loadToken() -> CKServerChangeToken? {
        guard let d = defaults.data(forKey: tokenKey) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: d)
    }
    private func saveToken(_ t: CKServerChangeToken?) {
        if let t, let d = try? NSKeyedArchiver.archivedData(withRootObject: t, requiringSecureCoding: true) { defaults.set(d, forKey: tokenKey) }
        else { defaults.removeObject(forKey: tokenKey) }
    }
}

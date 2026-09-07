import Foundation
import CloudKit
import os

/// Reading state in the user's CloudKit **private** database. One record per
/// volume in a custom zone, so `refresh()` is a change-token fetch rather
/// than a query (no schema indexes to deploy, works offline-first).
///
/// Conflict rule: newest `updatedAt` wins. This is the only file that may
/// import CloudKit.
public actor CloudKitSyncStore: SyncStore {
    public static let recordType = "ReadingProgress"
    private let container: CKContainer
    private let db: CKDatabase
    private let zoneID = CKRecordZone.ID(zoneName: "KanpekiProgress", ownerName: CKCurrentUserDefaultName)
    private let defaults: UserDefaults
    private let tokenKey = "KanpekiCKChangeToken"
    private let zoneKey = "KanpekiCKZoneCreated"
    private var cache: [String: ReadingProgress] = [:]
    private var dirty: Set<String> = []
    private let changes = Broadcaster<SyncChange>()
    private let log = Logger(subsystem: "com.dchroninger.kanpeki", category: "cloudkit")

    public private(set) var lastError: String?
    public private(set) var lastRefresh: Date?

    public init(containerIdentifier: String = UbiquityContainer.identifier, defaults: UserDefaults = .standard) {
        container = CKContainer(identifier: containerIdentifier)
        db = container.privateCloudDatabase
        self.defaults = defaults
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
                    guard case .success(let m) = result, let p = Self.progress(from: m.record) else { continue }
                    let key = id.recordName
                    if dirty.contains(key), let local = cache[key], local.updatedAt >= p.updatedAt { continue }
                    if cache[key] != p {
                        cache[key] = p
                        changes.send(SyncChange(id: ContentID(rawValue: key), progress: p))
                    }
                }
                for d in r.deletions { cache[d.recordID.recordName] = nil }
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

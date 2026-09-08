import Foundation
import SQLite3

/// Read-only JMdict store built by `tools/ml/build_jmdict.py`.
/// JMdict is © EDRDG under CC BY-SA 4.0; the app shows attribution.
public actor JMDict {
    public struct Form: Hashable, Sendable { public let text: String; public let common: Bool }
    public struct Sense: Hashable, Sendable {
        public let partsOfSpeech: [String]   // JMdict entity codes: v1, v5k, adj-i, n, …
        public let misc: [String]            // uk (usually kana), col, arch, …
        public let glosses: [String]
    }
    public struct Entry: Hashable, Sendable, Identifiable {
        public let id: Int
        public let sequence: Int
        public let common: Bool
        public let kanji: [Form]
        public let readings: [Form]
        public let senses: [Sense]
        /// Best display headword: first kanji form unless the entry is usually kana.
        public var headword: String {
            let usuallyKana = senses.first?.misc.contains("uk") ?? false
            return (usuallyKana ? readings.first?.text : kanji.first?.text) ?? readings.first?.text ?? "?"
        }
        public var reading: String? { readings.first?.text }
        public var isVerbOrAdjective: Bool { senses.contains { $0.partsOfSpeech.contains { $0.hasPrefix("v") || $0.hasPrefix("adj") } } }
    }

    /// Owns the C handles; only ever touched from inside the actor.
    private final class Handles: @unchecked Sendable {
        let db: OpaquePointer
        let formStmt, entryStmt, formsStmt, sensesStmt: OpaquePointer
        init(db: OpaquePointer, formStmt: OpaquePointer, entryStmt: OpaquePointer, formsStmt: OpaquePointer, sensesStmt: OpaquePointer) {
            self.db = db; self.formStmt = formStmt; self.entryStmt = entryStmt; self.formsStmt = formsStmt; self.sensesStmt = sensesStmt
        }
        deinit {
            for s in [formStmt, entryStmt, formsStmt, sensesStmt] { sqlite3_finalize(s) }
            sqlite3_close(db)
        }
    }
    private let h: Handles
    private var formStmt: OpaquePointer? { h.formStmt }
    private var entryStmt: OpaquePointer? { h.entryStmt }
    private var formsStmt: OpaquePointer? { h.formsStmt }
    private var sensesStmt: OpaquePointer? { h.sensesStmt }
    private let entityNames: [String: String]

    public init(url: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let handle else {
            throw Error.cannotOpen(url.lastPathComponent)
        }
        func prep(_ sql: String) throws -> OpaquePointer {
            var s: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &s, nil) == SQLITE_OK, let s else { throw Error.badSchema(sql) }
            return s
        }
        h = Handles(db: handle,
                    formStmt: try prep("SELECT DISTINCT entry_id FROM forms WHERE text = ?"),
                    entryStmt: try prep("SELECT seq, common FROM entries WHERE id = ?"),
                    formsStmt: try prep("SELECT text, kind, common FROM forms WHERE entry_id = ? ORDER BY rowid"),
                    sensesStmt: try prep("SELECT pos, misc, gloss FROM senses WHERE entry_id = ? ORDER BY ord"))
        let meta = try prep("SELECT key, value FROM meta WHERE key LIKE 'ent:%'")
        var names: [String: String] = [:]
        while sqlite3_step(meta) == SQLITE_ROW {
            names[String(cString: sqlite3_column_text(meta, 0)).replacingOccurrences(of: "ent:", with: "")] = String(cString: sqlite3_column_text(meta, 1))
        }
        sqlite3_finalize(meta)
        entityNames = names
    }

    public enum Error: Swift.Error { case cannotOpen(String), badSchema(String) }

    /// Human name for an entity code, e.g. "v5k" → "Godan verb with 'ku' ending".
    public func describe(_ code: String) -> String { entityNames[code] ?? code }

    /// Entries whose kanji or reading form equals `form` exactly.
    public func entries(matching form: String) -> [Entry] {
        guard let formStmt else { return [] }
        sqlite3_reset(formStmt); sqlite3_bind_text(formStmt, 1, form, -1, SQLITE_TRANSIENT)
        var ids: [Int] = []
        while sqlite3_step(formStmt) == SQLITE_ROW { ids.append(Int(sqlite3_column_int64(formStmt, 0))) }
        return ids.compactMap(entry(id:))
    }

    public func entry(id: Int) -> Entry? {
        guard let entryStmt, let formsStmt, let sensesStmt else { return nil }
        sqlite3_reset(entryStmt); sqlite3_bind_int64(entryStmt, 1, Int64(id))
        guard sqlite3_step(entryStmt) == SQLITE_ROW else { return nil }
        let seq = Int(sqlite3_column_int64(entryStmt, 0)), common = sqlite3_column_int(entryStmt, 1) != 0
        var kanji: [Form] = [], readings: [Form] = []
        sqlite3_reset(formsStmt); sqlite3_bind_int64(formsStmt, 1, Int64(id))
        while sqlite3_step(formsStmt) == SQLITE_ROW {
            let f = Form(text: String(cString: sqlite3_column_text(formsStmt, 0)), common: sqlite3_column_int(formsStmt, 2) != 0)
            if String(cString: sqlite3_column_text(formsStmt, 1)) == "k" { kanji.append(f) } else { readings.append(f) }
        }
        var senses: [Sense] = []
        sqlite3_reset(sensesStmt); sqlite3_bind_int64(sensesStmt, 1, Int64(id))
        while sqlite3_step(sensesStmt) == SQLITE_ROW {
            func list(_ i: Int32) -> [String] { String(cString: sqlite3_column_text(sensesStmt, i)).split(separator: ";").map(String.init).filter { !$0.isEmpty } }
            senses.append(Sense(partsOfSpeech: list(0), misc: list(1),
                                glosses: String(cString: sqlite3_column_text(sensesStmt, 2)).components(separatedBy: " | ")))
        }
        return Entry(id: id, sequence: seq, common: common, kanji: kanji, readings: readings, senses: senses)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

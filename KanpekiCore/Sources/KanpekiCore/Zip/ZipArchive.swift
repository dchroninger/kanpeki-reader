import Foundation
import Compression
import CryptoKit

/// Random-access ZIP reader. Parses the central directory once, then reads
/// entries by byte range. STORED entries are a slice of the mmap'd file —
/// no copy, no inflate. DEFLATE goes through `Compression`. Never extracts
/// a whole archive.
public final class ZipArchive: Sendable {
    public struct Entry: Hashable, Sendable {
        public enum Method: Hashable, Sendable { case stored, deflate, other(UInt16) }
        public let name: String
        public let method: Method
        public let compressedSize: UInt64
        public let uncompressedSize: UInt64
        public let crc32: UInt32
        public let localHeaderOffset: UInt64
        public var isDirectory: Bool { name.hasSuffix("/") }
    }

    public enum ZipError: Error, LocalizedError, Sendable {
        case notAZip, truncated, badSignature(UInt32, at: UInt64), unsupportedMethod(UInt16)
        case inflateFailed(String), encrypted(String)
        public var errorDescription: String? {
            switch self {
            case .notAZip: "Not a ZIP archive (no end-of-central-directory record)"
            case .truncated: "ZIP truncated"
            case .badSignature(let s, let at): "Bad signature \(String(s, radix: 16)) at \(at)"
            case .unsupportedMethod(let m): "Unsupported compression method \(m)"
            case .inflateFailed(let n): "Inflate failed for \(n)"
            case .encrypted(let n): "Entry \(n) is encrypted"
            }
        }
    }

    public let url: URL
    public let entries: [Entry]
    /// SHA-256 of the raw central directory. Basis of `ContentID`.
    public let centralDirectoryDigest: Data
    public var contentID: ContentID {
        ContentID(rawValue: centralDirectoryDigest.map { String(format: "%02x", $0) }.joined())
    }
    private let data: Data

    /// Image entries in page order (natural sort). Skips `__MACOSX`, dotfiles,
    /// directories, and non-image names. Cover is index 0.
    public let pages: [Entry]

    public static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "heic", "avif", "bmp", "tif", "tiff", "jxl"]

    public convenience init(url: URL) throws {
        // alwaysMapped keeps the 10 GB library out of RAM; a page read faults
        // in only the pages it touches.
        let d = try Data(contentsOf: url, options: [.alwaysMapped])
        try self.init(data: d, url: url)
    }

    public init(data: Data, url: URL) throws {
        self.url = url
        self.data = data
        let r = Reader(data)
        let (cdOffset, cdSize, count) = try r.locateCentralDirectory()
        guard cdOffset + cdSize <= UInt64(data.count) else { throw ZipError.truncated }
        var es: [Entry] = []
        es.reserveCapacity(Int(count))
        var p = cdOffset
        for _ in 0..<count {
            let sig = try r.u32(p)
            guard sig == 0x0201_4b50 else { throw ZipError.badSignature(sig, at: p) }
            let flags = try r.u16(p + 8)
            let method = try r.u16(p + 10)
            let crc = try r.u32(p + 16)
            var csize = UInt64(try r.u32(p + 20))
            var usize = UInt64(try r.u32(p + 24))
            let nameLen = UInt64(try r.u16(p + 28))
            let extraLen = UInt64(try r.u16(p + 30))
            let commentLen = UInt64(try r.u16(p + 32))
            var local = UInt64(try r.u32(p + 42))
            let nameBytes = try r.bytes(p + 46, nameLen)
            let name = Self.decodeName(nameBytes, utf8Flag: flags & 0x800 != 0)
            // Zip64 extra (0x0001): only fields that overflowed are present, in this order.
            var q = p + 46 + nameLen
            let extraEnd = q + extraLen
            while q + 4 <= extraEnd {
                let id = try r.u16(q), len = UInt64(try r.u16(q + 2))
                if id == 0x0001 {
                    var f = q + 4
                    if usize == 0xFFFF_FFFF { usize = try r.u64(f); f += 8 }
                    if csize == 0xFFFF_FFFF { csize = try r.u64(f); f += 8 }
                    if local == 0xFFFF_FFFF { local = try r.u64(f); f += 8 }
                }
                q += 4 + len
            }
            let m: Entry.Method = switch method { case 0: .stored; case 8: .deflate; default: .other(method) }
            if flags & 0x1 != 0 { throw ZipError.encrypted(name) }
            es.append(Entry(name: name, method: m, compressedSize: csize, uncompressedSize: usize,
                            crc32: crc, localHeaderOffset: local))
            p += 46 + nameLen + extraLen + commentLen
        }
        self.entries = es
        self.centralDirectoryDigest = Data(SHA256.hash(data: data[Int(cdOffset)..<Int(cdOffset + cdSize)]))
        self.pages = es.filter { e in
            guard !e.isDirectory else { return false }
            let comps = e.name.split(separator: "/")
            guard let last = comps.last, !last.hasPrefix("."), !comps.contains("__MACOSX") else { return false }
            let ext = (last as NSString).pathExtension.lowercased()
            return Self.imageExtensions.contains(ext)
        }.sorted { NaturalSort.isOrderedBefore($0.name, $1.name) }
    }

    public func entry(named name: String) -> Entry? { entries.first { $0.name == name } }

    /// Decoded bytes of an entry. STORED: zero-copy slice of the mapping.
    public func data(for e: Entry) throws -> Data {
        let r = Reader(data)
        let sig = try r.u32(e.localHeaderOffset)
        guard sig == 0x0403_4b50 else { throw ZipError.badSignature(sig, at: e.localHeaderOffset) }
        let nameLen = UInt64(try r.u16(e.localHeaderOffset + 26))
        let extraLen = UInt64(try r.u16(e.localHeaderOffset + 28))
        let start = e.localHeaderOffset + 30 + nameLen + extraLen
        guard start + e.compressedSize <= UInt64(data.count) else { throw ZipError.truncated }
        let raw = data[Int(start)..<Int(start + e.compressedSize)]
        switch e.method {
        case .stored:
            return raw
        case .deflate:
            return try Self.inflate(raw, expected: Int(e.uncompressedSize), name: e.name)
        case .other(let m):
            throw ZipError.unsupportedMethod(m)
        }
    }

    public func pageData(_ index: Int) throws -> Data {
        guard pages.indices.contains(index) else { throw LibraryError.pageOutOfRange(index) }
        return try data(for: pages[index])
    }

    // MARK: - Internals

    static func inflate(_ src: Data, expected: Int, name: String) throws -> Data {
        guard expected > 0 else { return Data() }
        var out = Data(count: expected)
        let n = out.withUnsafeMutableBytes { dst -> Int in
            src.withUnsafeBytes { s -> Int in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, expected,
                                          s.bindMemory(to: UInt8.self).baseAddress!, src.count,
                                          nil, COMPRESSION_ZLIB)  // raw DEFLATE, as ZIP uses
            }
        }
        guard n == expected else { throw ZipError.inflateFailed(name) }
        return out
    }

    static func decodeName(_ b: Data, utf8Flag: Bool) -> String {
        if let s = String(data: b, encoding: .utf8) { return s }
        // Non-flagged archives from Japanese sources are usually CP932.
        if let s = String(data: b, encoding: .shiftJIS) { return s }
        return String(data: b, encoding: .isoLatin1) ?? String(decoding: b, as: UTF8.self)
    }

    private struct Reader {
        let d: Data
        init(_ d: Data) { self.d = d }
        func u16(_ o: UInt64) throws -> UInt16 {
            guard o + 2 <= UInt64(d.count) else { throw ZipError.truncated }
            let i = d.startIndex + Int(o)
            return UInt16(d[i]) | UInt16(d[i + 1]) << 8
        }
        func u32(_ o: UInt64) throws -> UInt32 {
            guard o + 4 <= UInt64(d.count) else { throw ZipError.truncated }
            let i = d.startIndex + Int(o)
            return UInt32(d[i]) | UInt32(d[i + 1]) << 8 | UInt32(d[i + 2]) << 16 | UInt32(d[i + 3]) << 24
        }
        func u64(_ o: UInt64) throws -> UInt64 {
            UInt64(try u32(o)) | UInt64(try u32(o + 4)) << 32
        }
        func bytes(_ o: UInt64, _ n: UInt64) throws -> Data {
            guard o + n <= UInt64(d.count) else { throw ZipError.truncated }
            let i = d.startIndex + Int(o)
            return d[i..<i + Int(n)]
        }

        /// Returns (offset, size, entryCount) of the central directory, Zip64-aware.
        func locateCentralDirectory() throws -> (UInt64, UInt64, UInt64) {
            let n = UInt64(d.count)
            guard n >= 22 else { throw ZipError.notAZip }
            let minPos = n > 22 + 65535 ? n - 22 - 65535 : 0
            var p = n - 22
            var found: UInt64? = nil
            while true {
                if try u32(p) == 0x0605_4b50 { found = p; break }
                if p == minPos { break }
                p -= 1
            }
            guard let eocd = found else { throw ZipError.notAZip }
            var count = UInt64(try u16(eocd + 10))
            var size = UInt64(try u32(eocd + 12))
            var offset = UInt64(try u32(eocd + 16))
            if count == 0xFFFF || size == 0xFFFF_FFFF || offset == 0xFFFF_FFFF, eocd >= 20 {
                let loc = eocd - 20
                if try u32(loc) == 0x0706_4b50 {
                    let z64 = try u64(loc + 8)
                    guard try u32(z64) == 0x0606_4b50 else { throw ZipError.badSignature(try u32(z64), at: z64) }
                    count = try u64(z64 + 32)
                    size = try u64(z64 + 40)
                    offset = try u64(z64 + 48)
                }
            }
            return (offset, size, count)
        }
    }
}

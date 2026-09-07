import Foundation
import SwiftData
import ImageIO
import UniformTypeIdentifiers
import os

public struct ScanSummary: Sendable, Hashable {
    public var scanned = 0, provisional = 0, removed = 0, unchanged = 0, failed = 0
    public init() {}
}

/// Walks the monitor's item list and keeps the SwiftData cache in step.
///
/// - Local archive, not yet scanned or changed on disk → open, hash, read
///   ComicInfo.xml (else filename), index pages, thumbnail the cover.
/// - Remote (not downloaded) archive → provisional row from the filename so
///   the library lists it; upgraded to a real row after download.
/// - Rows whose file vanished → deleted.
@ModelActor
public actor LibraryScanner {
    private let log = Logger(subsystem: "com.dchroninger.kanpeki", category: "scanner")

    public func scan(_ items: [CloudFileItem], progress: (@Sendable (Int, Int) -> Void)? = nil) throws -> ScanSummary {
        var summary = ScanSummary()
        let existing = try modelContext.fetch(FetchDescriptor<VolumeRecord>())
        var byPath = Dictionary(uniqueKeysWithValues: existing.map { ($0.relativePath, $0) })
        let seen = Set(items.map(\.relativePath))

        for (i, item) in items.enumerated() {
            progress?(i, items.count)
            let rec = byPath[item.relativePath]
            byPath[item.relativePath] = nil
            if item.isLocal {
                if let rec, rec.isScanned, rec.fileSize == item.size, rec.modified == item.modified {
                    summary.unchanged += 1; continue
                }
                do {
                    try Self.fill(rec ?? insert(item), from: item)
                    summary.scanned += 1
                } catch {
                    log.error("scan failed \(item.name, privacy: .private): \(error.localizedDescription)")
                    summary.failed += 1
                    if rec == nil { _ = insert(item) }
                }
            } else if rec == nil {
                _ = insert(item); summary.provisional += 1
            } else {
                summary.unchanged += 1
            }
        }
        for (_, stale) in byPath where !seen.contains(stale.relativePath) {
            modelContext.delete(stale); summary.removed += 1
        }
        try modelContext.save()
        progress?(items.count, items.count)
        return summary
    }

    /// Everything this device has actually scanned, for publishing.
    public func exportIndex() throws -> [VolumeIndexEntry] {
        try modelContext.fetch(FetchDescriptor<VolumeRecord>()).compactMap { r in
            guard let cid = r.contentID else { return nil }
            return VolumeIndexEntry(relativePath: r.relativePath, contentID: cid, series: r.series, number: r.number,
                                    title: r.title, pageCount: r.pageCount, rightToLeft: r.rightToLeft,
                                    fileSize: r.fileSize, coverJPEG: r.coverThumbnail, updatedAt: r.scannedAt ?? .now)
        }
    }

    /// Fill rows this device could not scan (cloud placeholders) from what
    /// another device published. Rows scanned locally are left alone.
    @discardableResult
    public func apply(index: [String: VolumeIndexEntry]) throws -> Int {
        var n = 0
        for r in try modelContext.fetch(FetchDescriptor<VolumeRecord>()) where !r.isScanned {
            guard let e = index[r.relativePath] else { continue }
            r.contentID = e.contentID; r.series = e.series; r.number = e.number; r.title = e.title
            r.pageCount = e.pageCount; r.rightToLeft = e.rightToLeft
            if r.coverThumbnail == nil { r.coverThumbnail = e.coverJPEG }
            n += 1
        }
        if n > 0 { try modelContext.save() }
        return n
    }

    /// Drop every row. Used to prove the cache rebuilds from nothing.
    public func wipe() throws {
        try modelContext.delete(model: VolumeRecord.self)
        try modelContext.save()
    }

    public func count() throws -> Int { try modelContext.fetchCount(FetchDescriptor<VolumeRecord>()) }

    private func insert(_ item: CloudFileItem) -> VolumeRecord {
        let m = FilenameMetadata.parse(fileName: item.name, parentFolder: item.parentFolder)
        let r = VolumeRecord(relativePath: item.relativePath, series: m.series, number: m.number,
                             title: (item.name as NSString).deletingPathExtension, fileSize: item.size, modified: item.modified)
        modelContext.insert(r)
        return r
    }

    private static func fill(_ r: VolumeRecord, from item: CloudFileItem) throws {
        let zip = try Self.openCoordinated(item.url)
        r.contentID = zip.contentID.rawValue
        r.pageNames = zip.pages.map(\.name)
        r.pageCount = zip.pages.count
        r.fileSize = item.size
        r.modified = item.modified
        r.scannedAt = .now
        let fallback = FilenameMetadata.parse(fileName: item.name, parentFolder: item.parentFolder)
        if let e = zip.entry(named: ComicInfo.entryName), let ci = try? ComicInfo.parse(try zip.data(for: e)) {
            r.hasComicInfo = true
            r.series = ci.series?.nilIfEmpty ?? fallback.series
            r.number = ci.number?.nilIfEmpty ?? fallback.number
            r.title = ci.title?.nilIfEmpty ?? (item.name as NSString).deletingPathExtension
            r.rightToLeft = ci.manga == .unknown ? true : ci.rightToLeft
            r.doublePages = ci.pages.filter(\.doublePage).map(\.image)
        } else {
            r.hasComicInfo = false
            r.series = fallback.series; r.number = fallback.number
            r.title = (item.name as NSString).deletingPathExtension
            r.rightToLeft = true
            r.doublePages = []
        }
        if let first = zip.pages.first {
            r.coverThumbnail = Self.thumbnail(try zip.data(for: first), maxPixel: 400)
        }
    }

    static func openCoordinated(_ url: URL) throws -> ZipArchive {
        guard DownloadManager.isLocalNow(url) else { throw LibraryError.notAvailable(ContentID(rawValue: url.lastPathComponent)) }
        var result: Result<ZipArchive, Error>?
        var coordErr: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordErr) { u in
            result = Result { try ZipArchive(url: u) }
        }
        if let coordErr { throw coordErr }
        return try result!.get()
    }

    /// ImageIO thumbnail — never decodes the full page.
    public static func thumbnail(_ data: Data, maxPixel: Int) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(dst) ? out as Data : nil
    }
}

extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }

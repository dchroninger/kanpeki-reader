import Foundation
import ImageIO
import CoreGraphics
import KanpekiCore

/// Pages for one open volume: geometry known up front (header parse only),
/// bitmaps decoded at screen size on demand, prefetched around the current
/// page, and evicted under a byte budget — never an object count.
@MainActor
final class PageProvider {
    let source: CloudLibrarySource
    let volume: ContentID
    let pageCount: Int
    let maxPixel: Int
    /// Pixel size per page, in reading order. Filled by `loadGeometry()`.
    private(set) var sizes: [CGSize] = []

    private var cache: [Int: CGImage] = [:]
    private var lru: [Int] = []
    private var bytes = 0
    private let budget: Int
    private var inflight: [Int: Task<CGImage?, Never>] = [:]

    init(source: CloudLibrarySource, volume: ContentID, pageCount: Int, maxPixel: Int, budgetBytes: Int = 160 * 1024 * 1024) {
        self.source = source; self.volume = volume; self.pageCount = pageCount; self.maxPixel = maxPixel; self.budget = budgetBytes
    }

    /// Reads every page header. STORED archives make this a handful of
    /// milliseconds per page; DEFLATE has to inflate each entry once.
    func loadGeometry() async {
        var out = Array(repeating: CGSize(width: 2, height: 3), count: pageCount)
        for i in 0..<pageCount {
            guard let data = try? await source.pageData(volume: volume, index: i),
                  let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? CGFloat, let h = props[kCGImagePropertyPixelHeight] as? CGFloat
            else { continue }
            let rotated = ((props[kCGImagePropertyOrientation] as? UInt32) ?? 1) >= 5
            out[i] = rotated ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
        }
        sizes = out
    }

    func isWide(_ i: Int) -> Bool {
        guard sizes.indices.contains(i) else { return false }
        return sizes[i].width > sizes[i].height
    }

    // MARK: Spreads (decided from geometry: cover alone, wide pages alone)

    func spread(startingAt i: Int, twoUp: Bool) -> [Int] {
        guard i >= 0, i < pageCount else { return [] }
        if !twoUp || i == 0 || isWide(i) || i + 1 >= pageCount || isWide(i + 1) { return [i] }
        return [i, i + 1]
    }

    func spread(endingAt i: Int, twoUp: Bool) -> [Int] {
        guard i >= 0, i < pageCount else { return [] }
        if !twoUp || i == 0 || isWide(i) || i - 1 < 1 || isWide(i - 1) { return [i] }
        return [i - 1, i]
    }

    // MARK: Bitmaps

    func cached(_ i: Int) -> CGImage? {
        if let img = cache[i] { touch(i); return img }
        return nil
    }

    func image(_ i: Int) async -> CGImage? {
        if let img = cached(i) { return img }
        if let t = inflight[i] { return await t.value }
        let src = source, vol = volume, px = maxPixel
        let t = Task<CGImage?, Never>.detached(priority: .userInitiated) {
            guard let data = try? await src.pageData(volume: vol, index: i) else { return nil }
            return PageDecoder.decode(data, maxPixel: px)
        }
        inflight[i] = t
        let img = await t.value
        inflight[i] = nil
        if let img { insert(i, img) }
        return img
    }

    func prefetch(around i: Int, radius: Int = 2) {
        for d in 1...radius {
            for j in [i + d, i - d] where j >= 0 && j < pageCount && cache[j] == nil && inflight[j] == nil {
                Task { _ = await image(j) }
            }
        }
    }

    private func insert(_ i: Int, _ img: CGImage) {
        let cost = img.bytesPerRow * img.height
        cache[i] = img; touch(i); bytes += cost
        while bytes > budget, lru.count > 3, let victim = lru.first {
            lru.removeFirst()
            if let v = cache.removeValue(forKey: victim) { bytes -= v.bytesPerRow * v.height }
        }
    }

    private func touch(_ i: Int) {
        lru.removeAll { $0 == i }; lru.append(i)
    }
}

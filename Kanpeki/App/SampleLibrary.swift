import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import KanpekiCore

/// Synthetic STORED CBZs so the plumbing can be exercised on a simulator
/// with no library. Also the "something for the reviewer" placeholder.
@MainActor
enum SampleLibrary {
    static func write(into root: URL) throws {
        let dir = root.appending(path: "サンプル", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for vol in 1...2 {
            let pages = 12
            var entries: [ZipWriter.Entry] = []
            for i in 0..<pages {
                let wide = vol == 2 && i == 5
                entries.append(.init(name: String(format: "%03d.jpg", i), data: try page(vol: vol, index: i, count: pages, wide: wide)))
            }
            let ci = """
            <?xml version="1.0"?>
            <ComicInfo><Series>サンプル</Series><Number>\(vol)</Number><Volume>\(vol)</Volume>
            <LanguageISO>ja</LanguageISO><Manga>YesAndRightToLeft</Manga><PageCount>\(pages)</PageCount>
            <Pages><Page Image="0" Type="FrontCover"/>\(vol == 2 ? "<Page Image=\"5\" DoublePage=\"true\"/>" : "")</Pages></ComicInfo>
            """
            entries.append(.init(name: ComicInfo.entryName, data: Data(ci.utf8)))
            let url = dir.appending(path: "サンプル０\(vol).cbz")
            try ZipWriter.stored(entries).write(to: url, options: .atomic)
        }
    }

    private static func page(vol: Int, index: Int, count: Int, wide: Bool) throws -> Data {
        let w: CGFloat = wide ? 1600 : 800, h: CGFloat = 1200
        let view = ZStack {
            LinearGradient(colors: index == 0 ? [.red.opacity(0.9), .black] : [.white, Color(white: 0.85)], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 24) {
                Text(index == 0 ? "サンプル" : "第\(vol)巻").font(.system(size: 120, weight: .black))
                Text(index == 0 ? "第\(vol)巻" : "\(index) / \(count - 1)").font(.system(size: 80, weight: .bold, design: .rounded))
                if wide { Text("見開き").font(.system(size: 60)) }
            }.foregroundStyle(index == 0 ? .white : .black)
        }.frame(width: w, height: h)
        let r = ImageRenderer(content: view)
        r.scale = 1
        guard let cg = r.cgImage else { throw CocoaError(.fileWriteUnknown) }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(dst, cg, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        CGImageDestinationFinalize(dst)
        return out as Data
    }
}

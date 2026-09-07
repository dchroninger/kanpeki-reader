import Foundation

/// The de-facto ComicRack metadata file. Only the fields this app reads.
public struct ComicInfo: Hashable, Sendable, Codable {
    public enum MangaMode: String, Hashable, Sendable, Codable { case unknown = "Unknown", no = "No", yes = "Yes", yesAndRightToLeft = "YesAndRightToLeft" }
    public struct Page: Hashable, Sendable, Codable {
        public var image: Int
        public var type: String?
        public var doublePage: Bool
        public var imageWidth: Int?
        public var imageHeight: Int?
        public init(image: Int, type: String? = nil, doublePage: Bool = false, imageWidth: Int? = nil, imageHeight: Int? = nil) {
            self.image = image; self.type = type; self.doublePage = doublePage; self.imageWidth = imageWidth; self.imageHeight = imageHeight
        }
    }

    public var series: String?
    public var number: String?
    public var volume: Int?
    public var title: String?
    public var languageISO: String?
    public var manga: MangaMode = .unknown
    public var pageCount: Int?
    public var pages: [Page] = []

    public var rightToLeft: Bool { manga == .yesAndRightToLeft }

    public static let entryName = "ComicInfo.xml"

    public init() {}

    public static func parse(_ data: Data) throws -> ComicInfo {
        let d = Delegate()
        let p = XMLParser(data: data)
        p.delegate = d
        guard p.parse() else { throw d.error ?? p.parserError ?? CocoaError(.fileReadCorruptFile) }
        return d.info
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var info = ComicInfo()
        var path: [String] = []
        var text = ""
        var error: Error?

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            path.append(name); text = ""
            if name == "Page", path.contains("Pages") {
                guard let img = Int(attributes["Image"] ?? "") else { return }
                let dp = (attributes["DoublePage"] ?? "").lowercased() == "true"
                info.pages.append(Page(image: img, type: attributes["Type"], doublePage: dp,
                                       imageWidth: Int(attributes["ImageWidth"] ?? ""), imageHeight: Int(attributes["ImageHeight"] ?? "")))
            }
        }
        func parser(_ parser: XMLParser, foundCharacters s: String) { text += s }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            defer { path.removeLast() }
            guard path.count == 2 else { return } // direct children of ComicInfo only
            let v = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "Series": info.series = v
            case "Number": info.number = v
            case "Volume": info.volume = Int(v)
            case "Title": info.title = v
            case "LanguageISO": info.languageISO = v
            case "Manga": info.manga = MangaMode(rawValue: v) ?? .unknown
            case "PageCount": info.pageCount = Int(v)
            default: break
            }
        }
        func parser(_ parser: XMLParser, parseErrorOccurred e: Error) { error = e }
    }
}

/// Fallback when there is no ComicInfo.xml: `<series><fullwidth-number>[b].cbz`.
public enum FilenameMetadata {
    public struct Result: Hashable, Sendable {
        public let series: String
        public let number: String   // ASCII digits, optional suffix; "" if none
    }

    private static let fullwidth = "０１２３４５６７８９"

    public static func parse(fileName: String, parentFolder: String?) -> Result {
        let stem = (fileName as NSString).deletingPathExtension
        // trailing: digits (ASCII or fullwidth), optional single-letter suffix
        var chars = Array(stem)
        var suffix = ""
        if let last = chars.last, last.isLetter, last.isASCII, chars.count > 1, isDigit(chars[chars.count - 2]) {
            suffix = String(last); chars.removeLast()
        }
        var digits: [Character] = []
        while let c = chars.last, isDigit(c) { digits.insert(c, at: 0); chars.removeLast() }
        let series = String(chars).trimmingCharacters(in: .whitespaces)
        if digits.isEmpty {
            return Result(series: parentFolder ?? stem, number: "")
        }
        let ascii = String(digits.map { c -> Character in
            if let i = fullwidth.firstIndex(of: c) { return Character(String(fullwidth.distance(from: fullwidth.startIndex, to: i))) }
            return c
        })
        let trimmed = String(ascii.drop(while: { $0 == "0" }))
        return Result(series: series.isEmpty ? (parentFolder ?? stem) : series,
                      number: (trimmed.isEmpty ? "0" : trimmed) + suffix)
    }

    private static func isDigit(_ c: Character) -> Bool { c.isASCII && c.isNumber || fullwidth.contains(c) }
}

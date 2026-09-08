import Testing
import Foundation
import CoreML
import CoreGraphics
import CoreText
@testable import KanpekiOCR

/// Compiles the real packages from the app's resources and must reproduce
/// the string the Python parity check produced for the same synthetic image.
@Suite struct MangaOCRTests {
    static let models = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "Kanpeki/Resources/Models")

    static func compiled(_ name: String) throws -> URL {
        try MLModel.compileModel(at: models.appending(path: name + ".mlpackage"))
    }

    /// Vertical 今日は in a bold gothic, like the Python render.
    static func render(_ text: String) -> CGImage {
        let ctx = CGContext(data: nil, width: 224, height: 224, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 224, height: 224))
        let font = CTFontCreateWithName("HiraginoSans-W6" as CFString, 34, nil)
        var y: CGFloat = 224 - 20 - 34
        for ch in text {
            let attrs: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: 0, alpha: 1)]
            let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, String(ch) as CFString, attrs as CFDictionary))
            ctx.textPosition = CGPoint(x: 95, y: y); CTLineDraw(line, ctx); y -= 36
        }
        return ctx.makeImage()!
    }

    @Test func recognizesSyntheticVerticalText() async throws {
        guard FileManager.default.fileExists(atPath: Self.models.appending(path: "MangaOCREncoder.mlpackage").path) else {
            Issue.record("models not built; run tools/ml/convert_manga_ocr.py"); return
        }
        let ocr = try MangaOCR(encoderURL: try Self.compiled("MangaOCREncoder"), decoderURL: try Self.compiled("MangaOCRDecoder"),
                               vocabURL: Self.models.appending(path: "manga-ocr-vocab.txt"))
        let r = try await ocr.recognize(Self.render("今日は"))
        #expect(r.text == "今日は", "got \(r.text) tokens \(r.tokens)")
        #expect(r.tokens.last == 3)
        print("OCR \(r.text) in \(String(format: "%.2f", r.seconds))s")
    }

    @Test func postProcess() {
        #expect(MangaOCR.postProcess("こん にちは…") == "こんにちは．．．")
        #expect(MangaOCR.postProcess("A1!") == "Ａ１！")
    }
}

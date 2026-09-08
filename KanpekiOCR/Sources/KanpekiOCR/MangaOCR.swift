import Foundation
import CoreML
import CoreGraphics
import CoreVideo
import ImageIO

/// manga-ocr (kha-white, Apache-2.0) running on CoreML: a ViT encoder over
/// a 224×224 grayscale crop and a 2-layer BERT decoder driven by a greedy
/// loop here. Recognizes one text region (a speech bubble crop); it does
/// not find text.
public actor MangaOCR {
    public struct Config: Sendable { public let maxLength: Int; public let cls: Int32; public let sep: Int32; public let pad: Int32 }

    private let encoder: MLModel
    private let decoder: MLModel
    private let vocab: [String]
    public let config: Config

    /// `encoderURL`/`decoderURL` are compiled `.mlmodelc` bundles (Xcode
    /// compiles `.mlpackage` resources; tests call `MLModel.compileModel`).
    public init(encoderURL: URL, decoderURL: URL, vocabURL: URL, maxLength: Int = 128) throws {
        let cfg = MLModelConfiguration(); cfg.computeUnits = .cpuAndNeuralEngine   // ANE on device; the simulator has no MPSGraph
        encoder = try MLModel(contentsOf: encoderURL, configuration: cfg)
        decoder = try MLModel(contentsOf: decoderURL, configuration: cfg)
        vocab = try String(contentsOf: vocabURL, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        config = Config(maxLength: maxLength, cls: 2, sep: 3, pad: 0)
    }

    public struct Result: Sendable, Hashable {
        public let text: String
        public let tokens: [Int32]
        public let seconds: Double
    }

    /// Recognize the text in `image` (already cropped to the bubble).
    public func recognize(_ image: CGImage) throws -> Result {
        let t0 = Date()
        let pixels = try Self.grayscale224(image)
        let enc = try encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: pixels)]))
        guard let hidden = enc.featureValue(for: "encoder_hidden_states")?.multiArrayValue else { throw Error.badModelOutput("encoder_hidden_states") }
        var ids: [Int32] = [config.cls]
        for _ in 0..<(config.maxLength - 1) {
            let input = try MLMultiArray(shape: [1, NSNumber(value: ids.count)], dataType: .int32)
            for (i, t) in ids.enumerated() { input[i] = NSNumber(value: t) }
            let out = try decoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                "input_ids": MLFeatureValue(multiArray: input), "encoder_hidden_states": MLFeatureValue(multiArray: hidden)]))
            guard let logits = out.featureValue(for: "logits")?.multiArrayValue else { throw Error.badModelOutput("logits") }
            let next = Self.argmaxLastRow(logits, vocab: vocab.count)
            ids.append(next)
            if next == config.sep { break }
        }
        let text = Self.postProcess(ids.filter { $0 > 4 }.map { Int($0) < vocab.count ? vocab[Int($0)] : "" }.joined())
        return Result(text: text, tokens: ids, seconds: Date().timeIntervalSince(t0))
    }

    public enum Error: Swift.Error { case badModelOutput(String), cannotDraw }

    // MARK: - Internals

    /// logits shape [1, T, V]; argmax over the last position.
    private static func argmaxLastRow(_ a: MLMultiArray, vocab: Int) -> Int32 {
        let t = a.shape[1].intValue, v = a.shape[2].intValue
        let base = (t - 1) * v
        var best = 0; var bestVal = -Float.infinity
        a.withUnsafeBufferPointer(ofType: Float16.self) { p in
            for i in 0..<v { let x = Float(p[base + i]); if x > bestVal { bestVal = x; best = i } }
        }
        if bestVal == -Float.infinity {  // model emitted Float32
            a.withUnsafeBufferPointer(ofType: Float.self) { p in
                for i in 0..<v { let x = p[base + i]; if x > bestVal { bestVal = x; best = i } }
            }
        }
        return Int32(best)
    }

    /// manga-ocr preprocessing: convert to L, resize to 224×224 ignoring aspect.
    static func grayscale224(_ image: CGImage) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true]
        guard CVPixelBufferCreate(kCFAllocatorDefault, 224, 224, kCVPixelFormatType_OneComponent8, attrs as CFDictionary, &pb) == kCVReturnSuccess, let pb else { throw Error.cannotDraw }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: 224, height: 224, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { throw Error.cannotDraw }
        ctx.interpolationQuality = .high
        ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 224, height: 224))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 224, height: 224))
        return pb
    }

    /// manga-ocr's post_process: strip whitespace, normalise ellipses, ASCII → fullwidth.
    static func postProcess(_ s: String) -> String {
        var t = s.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "…", with: "...")
        t = t.replacingOccurrences(of: #"[・.]{2,}"#, with: "...", options: .regularExpression)
        return String(t.unicodeScalars.map { u -> Character in
            if u.value == 0x20 { return "　" }
            if (0x21...0x7E).contains(u.value) { return Character(UnicodeScalar(u.value + 0xFEE0)!) }
            return Character(u)
        })
    }
}

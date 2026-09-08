import Foundation
import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif
#if canImport(Translation)
import Translation
#endif

/// Whole-selection translation. On-device language model first (it copes
/// with manga register and can explain an idiom); Apple Translation when
/// the model isn't available on this device. Nothing leaves the device.
struct BubbleTranslation: Equatable {
    enum Backend: String { case languageModel = "On-device model", appleTranslate = "Apple Translate" }
    var text: String
    var note: String?
    var backend: Backend
}

#if canImport(FoundationModels)
@Generable(description: "A translation of Japanese manga dialogue for an English-speaking learner.")
struct GeneratedTranslation {
    @Guide(description: "Natural English translation. Keep the speaker's tone; do not add commentary here.")
    var translation: String
    @Guide(description: "At most one short sentence about an idiom, slang, honorific, or dropped subject that a learner might miss. Empty if nothing notable.")
    var note: String
}
#endif

@MainActor
enum LanguageModelTranslator {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if case .available = SystemLanguageModel.default.availability { return true }
        #endif
        return false
    }

    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if case .unavailable(let r) = SystemLanguageModel.default.availability { return "\(r)" }
        return nil
        #else
        return "Foundation Models not supported"
        #endif
    }

    static func translate(_ text: String) async throws -> BubbleTranslation {
        #if canImport(FoundationModels)
        let session = LanguageModelSession(instructions: """
            You translate Japanese manga dialogue into natural English for a learner. \
            The text was recognized by OCR from a speech bubble: it may lack punctuation, \
            contain furigana artifacts, or be a fragment. Translate what is there; do not invent.
            """)
        let r = try await session.respond(to: "Japanese: \(text)", generating: GeneratedTranslation.self)
        let note = r.content.note.trimmingCharacters(in: .whitespacesAndNewlines)
        return BubbleTranslation(text: r.content.translation.trimmingCharacters(in: .whitespacesAndNewlines),
                                 note: note.isEmpty ? nil : note, backend: .languageModel)
        #else
        throw CocoaError(.featureUnsupported)
        #endif
    }
}

/// OCR output has no line breaks; sentence boundaries help every translator.
enum SentenceSplitter {
    static func split(_ text: String) -> [String] {
        var out: [String] = []; var cur = ""
        for ch in text {
            cur.append(ch)
            if "。！？!?".contains(ch) { out.append(cur); cur = "" }
        }
        if !cur.trimmingCharacters(in: .whitespaces).isEmpty { out.append(cur) }
        return out.isEmpty ? [text] : out
    }
}

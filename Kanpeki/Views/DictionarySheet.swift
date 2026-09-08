import SwiftUI
import KanpekiDictionary
#if canImport(Translation)
import Translation
#endif

/// Recognized text on top; tap a character to look up from there. Results
/// come from JMdict via deinflection + longest-match scan.
struct DictionarySheet: View {
    @Environment(AppModel.self) private var model
    let text: String
    let seconds: Double
    @State private var start = 0
    @State private var matches: [DictionaryMatch] = []
    @State private var translation: BubbleTranslation?
    @State private var translating = true
    @State private var translationError: String?
    @AppStorage("preferLanguageModel") private var preferLanguageModel = true
    #if canImport(Translation)
    @State private var fallbackConfig: TranslationSession.Configuration?
    #endif

    private var chars: [Character] { Array(text) }
    private var highlight: Range<Int> { start..<min(start + (matches.first?.matchedLength ?? 1), chars.count) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    FlowText(chars: chars, highlight: highlight) { start = $0; lookup() }
                        .padding(.vertical, 4)
                    translationRow
                    HStack {
                        Button("Copy", systemImage: "doc.on.doc") { copy(text) }.buttonStyle(.glass)
                        if let t = translation { Button("Copy translation", systemImage: "doc.on.doc.fill") { copy(t.text) }.buttonStyle(.glass) }
                        Spacer()
                        Text("OCR \(String(format: "%.1f", seconds))s").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                if matches.isEmpty {
                    ContentUnavailableView("No entry", systemImage: "character.book.closed", description: Text("Tap a different character to look up from there."))
                } else {
                    ForEach(matches) { m in EntryRow(match: m) }
                }
            }
            .listStyle(.plain)
            .navigationTitle("辞書")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        .task { lookup(); await translate() }
        #if canImport(Translation)
        .translationTask(fallbackConfig) { session in
            // TranslationSession isn't Sendable; the framework hands it to this
            // closure and expects the calls to happen right here.
            nonisolated(unsafe) let s = session
            do {
                var pieces: [String] = []
                for part in SentenceSplitter.split(text) { pieces.append(try await s.translate(part).targetText) }
                translation = BubbleTranslation(text: pieces.joined(separator: " "), note: nil, backend: .appleTranslate)
            } catch { translationError = error.localizedDescription }
            translating = false
        }
        #endif
    }

    @ViewBuilder private var translationRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let t = translation {
                Text(t.text).font(.body)
                if let n = t.note { Text(n).font(.footnote).foregroundStyle(.secondary).italic() }
                Text(t.backend.rawValue).font(.caption2).foregroundStyle(.tertiary)
            } else if translating {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Translating…").foregroundStyle(.secondary) }
            } else if let e = translationError {
                Text(e).font(.footnote).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }

    /// On-device language model when present and preferred; else Apple Translation.
    private func translate() async {
        translating = true; translationError = nil
        if preferLanguageModel, LanguageModelTranslator.isAvailable {
            do {
                translation = try await LanguageModelTranslator.translate(text)
                translating = false
                return
            } catch { translationError = "Model: \(error.localizedDescription)" }
        }
        #if canImport(Translation)
        translationError = nil
        fallbackConfig = TranslationSession.Configuration(source: Locale.Language(identifier: "ja"), target: Locale.Language(identifier: "en"))
        #else
        translating = false
        translationError = translationError ?? "No translator available"
        #endif
    }

    private func lookup() {
        guard let dict = model.loadDictionary() else { return }
        let from = String(chars[start...])
        Task { matches = await dict.lookup(from) }
    }

    private func copy(_ s: String) {
        #if os(iOS)
        UIPasteboard.general.string = s
        #else
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
        #endif
    }
}

/// Characters laid out as tappable cells; the current match is highlighted.
private struct FlowText: View {
    let chars: [Character]
    let highlight: Range<Int>
    let onTap: (Int) -> Void
    var body: some View {
        let cols = [GridItem(.adaptive(minimum: 26), spacing: 2)]
        LazyVGrid(columns: cols, alignment: .leading, spacing: 4) {
            ForEach(Array(chars.enumerated()), id: \.offset) { i, c in
                Text(String(c)).font(.title3)
                    .frame(width: 26, height: 30)
                    .background(highlight.contains(i) ? Color.yellow.opacity(0.35) : Color.clear, in: .rect(cornerRadius: 4))
                    .contentShape(Rectangle())
                    .onTapGesture { onTap(i) }
            }
        }
    }
}

private struct EntryRow: View {
    @Environment(AppModel.self) private var model
    let match: DictionaryMatch
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(match.entry.headword).font(.title2.weight(.semibold))
                if let r = match.entry.reading, r != match.entry.headword { Text(r).foregroundStyle(.secondary) }
                if match.entry.common { Text("common").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2).background(.green.opacity(0.2), in: .capsule) }
                Spacer()
            }
            if !match.reasons.isEmpty {
                Text(match.reasons.joined(separator: " ← ")).font(.caption).foregroundStyle(.orange)
            }
            ForEach(Array(match.entry.senses.prefix(4).enumerated()), id: \.offset) { i, s in
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.partsOfSpeech.map { pos(code: $0) }.joined(separator: ", ")).font(.caption2).foregroundStyle(.tertiary)
                    Text("\(i + 1). " + s.glosses.joined(separator: "; ")).font(.body)
                }
            }
        }
        .padding(.vertical, 4)
    }
    private func pos(code: String) -> String {
        // Keep the JMdict codes readable without a blocking actor hop.
        switch code {
        case "n": "noun"; case "v1": "ichidan verb"; case "vt": "transitive"; case "vi": "intransitive"
        case "adj-i": "i-adjective"; case "adj-na": "na-adjective"; case "adv": "adverb"; case "exp": "expression"
        case "int": "interjection"; case "prt": "particle"; case "pn": "pronoun"; case "vs": "suru verb"; case "aux-v": "auxiliary verb"
        default: code.hasPrefix("v5") ? "godan verb" : code
        }
    }
}

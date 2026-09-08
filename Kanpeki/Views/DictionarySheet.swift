import SwiftUI
import KanpekiDictionary
#if canImport(Translation)
import Translation
#endif

/// The recognized bubble as words. Tap a word for one card: reading with
/// pitch, inflection chain, top glosses; "More" for alternates. Translation
/// sits blurred until revealed (or always shown, by preference).
struct DictionarySheet: View {
    @Environment(AppModel.self) private var model
    let text: String
    let seconds: Double
    @State private var segments: [Segment] = []
    @State private var selected: Segment?
    @State private var showMore = false
    @State private var translation: BubbleTranslation?
    @State private var translating = true
    @State private var translationError: String?
    @State private var revealed = false
    @State private var appeared = false
    @AppStorage("preferLanguageModel") private var preferLanguageModel = true
    @AppStorage("alwaysShowTranslation") private var alwaysShowTranslation = false
    @AppStorage("showFurigana") private var showFurigana = false
    #if canImport(Translation)
    @State private var fallbackConfig: TranslationSession.Configuration?
    #endif

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    wordFlow
                    translationRow
                    if let s = selected, let m = s.best {
                        WordCard(segment: s, match: m, showMore: $showMore)
                            .id(s.id)
                            .transition(.asymmetric(insertion: .scale(scale: 0.96).combined(with: .opacity), removal: .opacity))
                    }
                }
                .padding(.horizontal).padding(.top, 4)
            }
            .navigationTitle("辞書")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Toggle(isOn: $showFurigana) { Label("Furigana", systemImage: "textformat.abc.dottedunderline") }
                        .toggleStyle(.button).buttonStyle(.glass)
                }
            }
        }
        .task { await segment(); appeared = true; await translate() }
        .sensoryFeedback(.impact(weight: .light), trigger: selected?.id)
        #if canImport(Translation)
        .translationTask(fallbackConfig) { session in
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

    // MARK: Words

    private var wordFlow: some View {
        FlowLayout(spacing: 4, lineSpacing: 6) {
            ForEach(Array(segments.enumerated()), id: \.element.id) { i, seg in
                WordChip(segment: seg, selected: selected?.id == seg.id,
                         furigana: (showFurigana || selected?.id == seg.id) && seg.kind == .word)
                    // Chips land one after another, left to right.
                    .opacity(appeared ? 1 : 0).scaleEffect(appeared ? 1 : 0.7)
                    .animation(.spring(duration: 0.35, bounce: 0.3).delay(Double(i) * 0.035), value: appeared)
                    .onTapGesture {
                        guard seg.kind != .plain, seg.best != nil else { return }
                        withAnimation(.snappy(duration: 0.2)) { selected = selected?.id == seg.id ? nil : seg; showMore = false }
                    }
            }
        }
    }

    private func segment() async {
        guard let dict = model.loadDictionary() else { return }
        segments = await dict.segment(text)
    }

    // MARK: Translation

    @ViewBuilder private var translationRow: some View {
        let show = alwaysShowTranslation || revealed
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 12))
        .blur(radius: show || translation == nil ? 0 : 7)   // errors and spinner stay legible
        .overlay {
            if !show, translation != nil {
                Label("Tap to reveal", systemImage: "eye.slash").font(.footnote).padding(.horizontal, 10).padding(.vertical, 6)
                    .glassEffect(.regular, in: .capsule)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeOut(duration: 0.25)) { revealed.toggle() } }
        .animation(.easeOut(duration: 0.25), value: show)
    }

    private func translate() async {
        translating = true; translationError = nil
        if preferLanguageModel, LanguageModelTranslator.isAvailable {
            do { translation = try await LanguageModelTranslator.translate(text); translating = false; return }
            catch { translationError = "Model: \(error.localizedDescription)" }
        }
        #if canImport(Translation)
        translationError = nil
        fallbackConfig = TranslationSession.Configuration(source: Locale.Language(identifier: "ja"), target: Locale.Language(identifier: "en"))
        #else
        translating = false; translationError = translationError ?? "No translator available"
        #endif
    }
}

private struct WordChip: View {
    let segment: Segment
    let selected: Bool
    let furigana: Bool

    private var tint: Color {
        switch segment.kind {
        case .plain: .clear
        case .particle: .secondary.opacity(0.15)
        case .word: (segment.best?.entry.isVerbOrAdjective ?? false) ? .orange.opacity(0.18) : .blue.opacity(0.16)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Height is always reserved so toggling furigana never moves the kanji.
            Text(segment.best?.entry.reading ?? " ")
                .font(.system(size: 9)).foregroundStyle(.secondary).frame(height: 11).opacity(furigana ? 1 : 0)
            Text(segment.text)
                .font(.title3)
                .foregroundStyle(segment.kind == .particle ? .secondary : .primary)
                .padding(.horizontal, 5).padding(.vertical, 3)
                .background(selected ? Color.yellow.opacity(0.45) : tint, in: .rect(cornerRadius: 6))
        }
    }
}

private struct WordCard: View {
    @Environment(AppModel.self) private var model
    let segment: Segment
    let match: DictionaryMatch
    @Binding var showMore: Bool
    @State private var pitch: [Int] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(match.entry.headword).font(.title.weight(.semibold))
                if let r = match.entry.reading, r != match.entry.headword { Text(r).font(.title3).foregroundStyle(.secondary) }
                if match.entry.common { Text("common").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2).background(.green.opacity(0.2), in: .capsule) }
                Spacer()
            }
            if let r = match.entry.reading, !pitch.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(pitch.prefix(2), id: \.self) { a in PitchAccentView(pattern: PitchPattern(reading: r, accent: a)) }
                }
                .padding(.top, 6)
            } else if match.entry.reading != nil {
                Text("pitch: unknown").font(.caption2).foregroundStyle(.tertiary)
            }
            if !match.reasons.isEmpty {
                Text("\(segment.text) ← " + match.reasons.joined(separator: " ← ")).font(.caption).foregroundStyle(.orange)
            }
            ForEach(Array(match.entry.senses.prefix(showMore ? 6 : 2).enumerated()), id: \.offset) { i, s in
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.partsOfSpeech.map(posName).joined(separator: ", ")).font(.caption2).foregroundStyle(.tertiary)
                    Text("\(i + 1). " + s.glosses.prefix(showMore ? 8 : 3).joined(separator: "; ")).font(.body)
                }
            }
            if segment.matches.count > 1 || match.entry.senses.count > 2 {
                DisclosureGroup("More", isExpanded: $showMore) {
                    ForEach(segment.matches.dropFirst()) { alt in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(alt.entry.headword).font(.headline)
                                if let r = alt.entry.reading, r != alt.entry.headword { Text(r).foregroundStyle(.secondary) }
                            }
                            Text(alt.entry.senses.first?.glosses.prefix(3).joined(separator: "; ") ?? "").font(.subheadline)
                        }
                        .padding(.vertical, 3)
                    }
                }
                .font(.subheadline)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 12))
        .task(id: match.id) {
            guard let d = model.loadDictionary() else { return }
            pitch = await d.pitchAccents(for: match.entry)
        }
    }

    private func posName(_ code: String) -> String {
        switch code {
        case "n": "noun"; case "v1": "ichidan verb"; case "vt": "transitive"; case "vi": "intransitive"
        case "adj-i": "i-adjective"; case "adj-na": "na-adjective"; case "adj-no": "no-adjective"; case "adv": "adverb"; case "exp": "expression"
        case "int": "interjection"; case "prt": "particle"; case "pn": "pronoun"; case "vs": "suru verb"; case "aux-v": "auxiliary verb"
        case "n-suf": "suffix"; case "pref": "prefix"; case "ctr": "counter"; case "num": "numeral"
        default: code.hasPrefix("v5") ? "godan verb" : code
        }
    }
}

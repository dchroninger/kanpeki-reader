import SwiftUI
import KanpekiCore
import KanpekiOCR

/// The reader. iOS pages with a finger-tracking page curl (`PagerView`);
/// macOS falls back to a static spread with tap/swipe. Chrome fades in on
/// open or a middle tap and drifts out after 4 s; a page turn snaps it away.
///
/// Direction follows the volume: RTL means the next page is to the left.
struct ProofReaderView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let volume: VolumeRef
    @State private var page = 0
    @State private var pageCount = 0
    @State private var visiblePages: [Int] = []
    @State private var provider: PageProvider?
    @State private var twoUp = false
    @State private var status = "Preparing…"
    @State private var ready = false
    @State private var remote: ReadingProgress?
    @State private var saveTask: Task<Void, Never>?
    @State private var errorText: String?
    @State private var chromeVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var textMode = false
    @State private var ocrBusy = false
    @State private var ocrResult: MangaOCR.Result?
    @State private var ocrError: String?
    // macOS-only static spread
    @State private var images: [(page: Int, image: CGImage)] = []
    @State private var flash: Edge?

    var body: some View {
        ZStack {
            pageArea.ignoresSafeArea()
            // Chrome and HUD stay inside the safe area (Dynamic Island, home indicator).
            VStack {
                chrome.opacity(chromeVisible ? 1 : 0).allowsHitTesting(chromeVisible)
                Spacer()
                hud.opacity(chromeVisible ? 1 : 0).allowsHitTesting(chromeVisible)
            }
            .overlay(alignment: .bottomTrailing) { if textMode { textModeHint } }
        }
        .task { await open() }
        .onDisappear { saveTask?.cancel(); hideTask?.cancel(); Task { await model.source?.release(volume: volume.id) } }
        .onChange(of: model.progress[volume.id]) { _, p in
            guard let p, p.device != DeviceName.current, ready, p.page != page else { return }
            remote = p; setChrome(true)
        }
        .sheet(item: $ocrResult) { r in
            DictionarySheet(text: r.text, seconds: r.seconds)
                .environment(model)
                .presentationDetents([.fraction(0.4), .medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationDragIndicator(.visible)
        }
        .alert("OCR", isPresented: Binding(get: { ocrError != nil }, set: { if !$0 { ocrError = nil } })) { Button("OK") {} } message: { Text(ocrError ?? "") }
        #if os(iOS)
        .statusBarHidden(true)
        #endif
    }

    private var pageArea: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                if let provider, ready {
                    #if os(iOS)
                    PagerView(provider: provider, rightToLeft: volume.rightToLeft, twoUp: twoUp, page: $page, visiblePages: $visiblePages,
                              textMode: textMode,
                              onUserTurn: { setChrome(false, fast: true); scheduleSave() },
                              onMiddleTap: { setChrome(!chromeVisible) },
                              onRegionSelected: { crop in Task { await recognize(crop) } })
                    #else
                    staticSpread(geo)
                    #endif
                } else if let errorText {
                    ContentUnavailableView("Can't open", systemImage: "exclamationmark.triangle", description: Text(errorText))
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(liveStatus).foregroundStyle(.white)
                        if case .downloading(let f) = liveAvailability { ProgressView(value: f).frame(width: 200).tint(.white) }
                    }
                }
            }
            .onChange(of: geo.size.width > geo.size.height, initial: true) { _, landscape in
                twoUp = landscape
                #if os(macOS)
                if ready { Task { await loadStatic() } }
                #endif
            }
        }
    }

    // MARK: Status

    private var liveStatus: String {
        switch liveAvailability {
        case .local: status
        case .remote(let b): "Waiting for iCloud download (\(b.formatted(.byteCount(style: .file))))…"
        case .downloading(let f): "Downloading from iCloud… \(Int(f * 100))%"
        case .unknown: status
        }
    }

    private var liveAvailability: Availability {
        model.volumes[volume.series]?.first { $0.id == volume.id }?.availability ?? volume.availability
    }

    private func setChrome(_ visible: Bool, autoHide: Bool = true, fast: Bool = false) {
        hideTask?.cancel()
        let duration = visible ? 0.15 : (fast ? 0.1 : 0.5)
        withAnimation(.easeInOut(duration: duration)) { chromeVisible = visible }
        // `-chromeHold YES` launch argument keeps chrome up for UI testing.
        guard visible, autoHide, !UserDefaults.standard.bool(forKey: "chromeHold") else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.5)) { chromeVisible = false }
        }
    }

    // MARK: Chrome + HUD

    private var chrome: some View {
        VStack(spacing: 8) {
            HStack {
                Button { dismiss() } label: { Image(systemName: "chevron.left").frame(width: 24, height: 24) }
                    .buttonStyle(.glass)
                Spacer()
                Text(volume.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    .padding(.horizontal, 12).padding(.vertical, 6).glassEffect(.regular, in: .capsule)
                Spacer()
                #if os(iOS)
                Button { toggleTextMode() } label: {
                    if ocrBusy { ProgressView().frame(width: 24, height: 24) } else { Text("文").font(.headline).frame(width: 24, height: 24) }
                }
                .buttonStyle(.glass).tint(textMode ? .yellow : nil)
                .disabled(ocrBusy)
                #else
                Color.clear.frame(width: 44, height: 24)
                #endif
            }
            if let r = remote {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath.icloud")
                    Text("Page \(r.page + 1) on \(r.device), \(r.updatedAt.formatted(.relative(presentation: .named)))")
                    Spacer()
                    Button("Go") { page = r.page; remote = nil; jumped() }.buttonStyle(.glassProminent)
                }
                .font(.callout).padding(.horizontal, 14).padding(.vertical, 8)
                .glassEffect(.regular, in: .rect(cornerRadius: 16))
            }
        }
        .padding(.horizontal).padding(.top, 8)
    }

    private var hud: some View {
        VStack(spacing: 4) {
            if ready, pageCount > 1 {
                Slider(value: Binding(get: { Double(page) }, set: { page = Int($0.rounded()) }), in: 0...Double(pageCount - 1), step: 1) { editing in
                    if editing { hideTask?.cancel() } else { jumped(); setChrome(true) }
                }
                .scaleEffect(x: volume.rightToLeft ? -1 : 1, y: 1)
            } else {
                Slider(value: .constant(0), in: 0...1).disabled(true)
            }
            Text(ready ? pageLabel : "—").font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .frame(maxWidth: 340)
        .glassEffect(.regular, in: .capsule)
        .padding(.bottom, 8)
    }

    private var textModeHint: some View {
        Text("Drag a box around the text").font(.footnote).padding(.horizontal, 12).padding(.vertical, 6)
            .glassEffect(.regular.tint(.yellow.opacity(0.35)), in: .capsule).padding(.trailing).padding(.bottom, 64)
    }

    private func toggleTextMode() {
        textMode.toggle()
        setChrome(true, autoHide: !textMode)
        if textMode, model.ocr == nil {
            ocrBusy = true
            Task { _ = await model.loadOCR(); ocrBusy = false; if let e = model.ocrLoadError { ocrError = e; textMode = false } }
        }
    }

    private func recognize(_ crop: CGImage) async {
        guard let ocr = await model.loadOCR() else { ocrError = model.ocrLoadError ?? "OCR unavailable"; return }
        ocrBusy = true
        defer { ocrBusy = false }
        do {
            let r = try await ocr.recognize(crop)
            if r.text.isEmpty { ocrError = "No text recognized" } else { ocrResult = r }
        } catch { ocrError = error.localizedDescription }
    }

    private var pageLabel: String {
        let shown = visiblePages.isEmpty ? [page] : visiblePages
        return shown.count == 2 ? "\(shown[0] + 1)–\(shown[1] + 1) / \(pageCount)" : "\(shown[0] + 1) / \(pageCount)"
    }

    /// Slider or remote banner moved `page`; the pager reacts to the binding.
    private func jumped() {
        scheduleSave()
        #if os(macOS)
        Task { await loadStatic() }
        #endif
    }

    // MARK: Open

    private func open() async {
        guard let source = model.source else { return }
        do {
            status = liveAvailability == .local ? "Opening…" : "Downloading from iCloud…"
            try await source.prepare(volume: volume.id)
            await model.refreshLists()
            pageCount = try await source.pageCount(volume: volume.id)
            if let p = try await model.sync.progress(for: volume.id) { page = min(p.page, max(pageCount - 1, 0)); model.noteProgress(p, for: volume.id) }
            status = "Reading page layout…"
            #if os(iOS)
            let px = Int(max(UIScreen.main.nativeBounds.width, UIScreen.main.nativeBounds.height))
            #else
            let px = 2200
            #endif
            let pv = PageProvider(source: source, volume: volume.id, pageCount: pageCount, maxPixel: px)
            await pv.loadGeometry()
            _ = await pv.image(page)
            pv.prefetch(around: page)
            provider = pv
            ready = true
            setChrome(true)
            #if os(macOS)
            await loadStatic()
            #endif
        } catch { errorText = error.localizedDescription }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let p = page, c = pageCount
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await model.setProgress(page: p, pageCount: c, for: volume.id)
        }
    }

    // MARK: macOS static spread (no UIKit curl on AppKit)

    #if os(macOS)
    @ViewBuilder
    private func staticSpread(_ geo: GeometryProxy) -> some View {
        let ordered = volume.rightToLeft ? images.reversed() : images
        let aspects = ordered.map { CGFloat($0.image.width) / CGFloat($0.image.height) }
        let h = min(geo.size.height, geo.size.width / max(aspects.reduce(0, +), 0.01))
        HStack(spacing: 0) {
            ForEach(Array(zip(ordered, aspects)), id: \.0.page) { item, a in
                Image(item.image, scale: 1, label: Text("Page \(item.page + 1)")).resizable().frame(width: a * h, height: h)
            }
        }
        .frame(width: geo.size.width, height: geo.size.height)
        .contentShape(Rectangle())
        .onTapGesture(coordinateSpace: .local) { pt in
            let w = geo.size.width, zone = min(w * 0.22, 90)
            if pt.x < zone { tapped(.leading) } else if pt.x > w - zone { tapped(.trailing) } else { setChrome(!chromeVisible) }
        }
        .gesture(DragGesture(minimumDistance: 30).onEnded { g in
            let dx = g.translation.width
            guard abs(dx) > abs(g.translation.height), abs(dx) > 40 else { return }
            dx > 0 ? tapped(.leading) : tapped(.trailing)
        })
    }

    private func tapped(_ side: Edge) {
        guard let provider else { return }
        let forward = volume.rightToLeft ? (side == .leading) : (side == .trailing)
        let next = forward ? provider.spread(startingAt: (visiblePages.last ?? page) + 1, twoUp: twoUp)
                           : provider.spread(endingAt: (visiblePages.first ?? page) - 1, twoUp: twoUp)
        guard let first = next.first else { return }
        page = first
        setChrome(false, fast: true)
        scheduleSave()
        Task { await loadStatic() }
    }

    private func loadStatic() async {
        guard let provider else { return }
        let pages = provider.spread(startingAt: page, twoUp: twoUp)
        var set: [(page: Int, image: CGImage)] = []
        for p in pages { if let img = await provider.image(p) { set.append((p, img)) } }
        images = set
        visiblePages = pages
        provider.prefetch(around: pages.last ?? page)
    }
    #endif
}

extension MangaOCR.Result: @retroactive Identifiable {
    public var id: String { text + String(tokens.count) }
}

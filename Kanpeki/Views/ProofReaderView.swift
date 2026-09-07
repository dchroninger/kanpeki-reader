import SwiftUI
import KanpekiCore

/// Phase 1 proof, not the reader: pages decoded on demand, paging by tap
/// zone or swipe, and the position round-tripping through `SyncStore`.
///
/// Direction follows the volume: RTL means the next page is to the left,
/// so "tap left / swipe rightwards" advances. LTR is the mirror.
///
/// Landscape shows two pages. Pairing is decided at display time from the
/// decoded geometry: a wide page (spread artwork, or every interior page of
/// a spread-format volume) and the cover always sit alone.
struct ProofReaderView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let volume: VolumeRef
    @State private var page = 0
    @State private var pageCount = 0
    @State private var images: [(page: Int, image: CGImage)] = []
    @State private var twoUp = false
    @State private var status = "Preparing…"
    @State private var ready = false
    @State private var remote: ReadingProgress?
    @State private var saveTask: Task<Void, Never>?
    @State private var errorText: String?
    @State private var flash: Edge?
    @State private var chromeVisible = true
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                if !images.isEmpty {
                    // Pages share one height and butt together with no gutter,
                    // so a spread split across two files reads as one image.
                    let ordered = volume.rightToLeft ? images.reversed() : images
                    let aspects = ordered.map { CGFloat($0.image.width) / CGFloat($0.image.height) }
                    let h = min(geo.size.height, geo.size.width / aspects.reduce(0, +))
                    HStack(spacing: 0) {
                        ForEach(Array(zip(ordered, aspects)), id: \.0.page) { item, a in
                            Image(item.image, scale: 1, label: Text("Page \(item.page + 1)"))
                                .resizable()
                                .frame(width: a * h, height: h)
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                } else if let errorText {
                    ContentUnavailableView("Can't open", systemImage: "exclamationmark.triangle", description: Text(errorText))
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(liveStatus).foregroundStyle(.white)
                        if case .downloading(let f) = liveAvailability { ProgressView(value: f).frame(width: 200).tint(.white) }
                    }
                }
                if let flash {
                    HStack { if flash == .trailing { Spacer() }
                        Rectangle().fill(.white.opacity(0.08)).frame(width: geo.size.width / 3)
                        if flash == .leading { Spacer() } }
                    .allowsHitTesting(false).transition(.opacity)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { pt in
                let w = geo.size.width
                if pt.x < w / 3 { tapped(.leading) } else if pt.x > w * 2 / 3 { tapped(.trailing) } else { setChrome(!chromeVisible) }
            }
            .gesture(DragGesture(minimumDistance: 30).onEnded { g in
                let dx = g.translation.width
                guard abs(dx) > abs(g.translation.height), abs(dx) > 40 else { return }
                // Swiping rightwards pulls in the page that sits to the left.
                dx > 0 ? tapped(.leading) : tapped(.trailing)
            })
            .onChange(of: geo.size.width > geo.size.height, initial: true) { _, landscape in
                twoUp = landscape
                if ready { Task { await load() } }
            }
        }
        .ignoresSafeArea()
        .overlay(alignment: .top) { chrome.opacity(chromeVisible ? 1 : 0).allowsHitTesting(chromeVisible) }
        .overlay(alignment: .bottom) { hud.opacity(chromeVisible ? 1 : 0).allowsHitTesting(chromeVisible) }
        .task { await open() }
        .onDisappear { saveTask?.cancel(); hideTask?.cancel(); Task { await model.source?.release(volume: volume.id) } }
        .onChange(of: model.progress[volume.id]) { _, p in
            guard let p, p.device != DeviceName.current, ready, p.page != page else { return }
            remote = p; setChrome(true, autoHide: false)
        }
        #if os(iOS)
        .statusBarHidden(true)
        #endif
    }

    /// Follows the monitor, so an eviction or a slow download shows as such.
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

    /// Chrome fades in fast (open, middle tap, remote-position banner) and
    /// drifts out after 4 s. A page turn snaps it away.
    private func setChrome(_ visible: Bool, autoHide: Bool = true, fast: Bool = false) {
        hideTask?.cancel()
        let duration = visible ? 0.15 : (fast ? 0.1 : 0.5)
        withAnimation(.easeInOut(duration: duration)) { chromeVisible = visible }
        guard visible, autoHide else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.5)) { chromeVisible = false }
        }
    }

    /// Which page sits on a given side depends on reading direction.
    private func tapped(_ side: Edge) {
        let forward = volume.rightToLeft ? (side == .leading) : (side == .trailing)
        step(forward ? max(images.count, 1) : -(twoUp ? 2 : 1), side: side)
    }

    private var chrome: some View {
        VStack(spacing: 8) {
            HStack {
                Button { dismiss() } label: { Image(systemName: "chevron.left").frame(width: 24, height: 24) }
                    .buttonStyle(.glass)
                Spacer()
                Text(volume.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    .padding(.horizontal, 12).padding(.vertical, 6).glassEffect(.regular, in: .capsule)
                Spacer()
                Color.clear.frame(width: 44, height: 24)
            }
            if let r = remote {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath.icloud")
                    Text("Page \(r.page + 1) on \(r.device), \(r.updatedAt.formatted(.relative(presentation: .named)))")
                    Spacer()
                    Button("Go") { page = r.page; remote = nil; Task { await load() } }.buttonStyle(.glassProminent)
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
                    if editing { hideTask?.cancel() } else { Task { await load() }; scheduleSave(); setChrome(true) }
                }
                // RTL volumes read right-to-left; flip the bar so it fills the same way.
                .scaleEffect(x: volume.rightToLeft ? -1 : 1, y: 1)
            } else {
                Slider(value: .constant(0), in: 0...1).disabled(true)
            }
            Text(ready ? pageLabel : "—").font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .frame(maxWidth: 340)
        .glassEffect(.regular, in: .capsule)
        .padding(.bottom, 20)
    }

    private var pageLabel: String {
        images.count == 2 ? "\(page + 1)–\(page + 2) / \(pageCount)" : "\(page + 1) / \(pageCount)"
    }

    private func step(_ d: Int, side: Edge) {
        let n = min(max(page + d, 0), pageCount - 1)
        guard n != page else { return }
        page = n
        setChrome(false, fast: true)
        withAnimation(.easeOut(duration: 0.12)) { flash = side }
        Task { try? await Task.sleep(for: .milliseconds(120)); withAnimation { flash = nil } }
        Task { await load() }
        scheduleSave()
    }

    private func open() async {
        guard let source = model.source else { return }
        do {
            status = liveAvailability == .local ? "Opening…" : "Downloading from iCloud…"
            try await source.prepare(volume: volume.id)
            await model.refreshLists()
            pageCount = try await source.pageCount(volume: volume.id)
            if let p = try await model.sync.progress(for: volume.id) { page = min(p.page, max(pageCount - 1, 0)); model.noteProgress(p, for: volume.id) }
            ready = true
            setChrome(true)
            await load()
        } catch { errorText = error.localizedDescription }
    }

    private func decode(_ index: Int) async throws -> CGImage? {
        guard let source = model.source else { return nil }
        let data = try await source.pageData(volume: volume.id, index: index)
        #if os(iOS)
        let px = Int(max(UIScreen.main.nativeBounds.width, UIScreen.main.nativeBounds.height))
        #else
        let px = 2200
        #endif
        return await Task.detached(priority: .userInitiated) { PageDecoder.decode(data, maxPixel: px) }.value
    }

    private func load() async {
        guard pageCount > 0 else { return }
        do {
            guard let first = try await decode(page) else { return }
            var set = [(page: page, image: first)]
            let wide = { (i: CGImage) in i.width > i.height }
            // Cover alone; wide pages alone; otherwise pair with the following page.
            if twoUp, page != 0, page + 1 < pageCount, !wide(first),
               let second = try await decode(page + 1), !wide(second) {
                set.append((page: page + 1, image: second))
            }
            images = set
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
}

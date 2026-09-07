import SwiftUI
import KanpekiCore

/// Phase 1 proof, not the reader: one page decoded at a time, paging by
/// tap zone or swipe, and the position round-tripping through `SyncStore`.
///
/// Direction follows the volume: RTL means the next page is to the left,
/// so "tap left / swipe rightwards" advances. LTR is the mirror.
struct ProofReaderView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let volume: VolumeRef
    @State private var page = 0
    @State private var pageCount = 0
    @State private var image: CGImage?
    @State private var status = "Preparing…"
    @State private var ready = false
    @State private var remote: ReadingProgress?
    @State private var saveTask: Task<Void, Never>?
    @State private var errorText: String?
    @State private var flash: Edge?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                if let image {
                    Image(image, scale: 1, label: Text("Page \(page + 1)")).resizable().aspectRatio(contentMode: .fit)
                        .frame(width: geo.size.width, height: geo.size.height)
                } else if let errorText {
                    ContentUnavailableView("Can't open", systemImage: "exclamationmark.triangle", description: Text(errorText))
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(status).foregroundStyle(.white)
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
                if pt.x < w / 3 { tapped(.leading) } else if pt.x > w * 2 / 3 { tapped(.trailing) }
            }
            .gesture(DragGesture(minimumDistance: 30).onEnded { g in
                let dx = g.translation.width
                guard abs(dx) > abs(g.translation.height), abs(dx) > 40 else { return }
                // Swiping rightwards pulls in the page that sits to the left.
                dx > 0 ? tapped(.leading) : tapped(.trailing)
            })
        }
        .ignoresSafeArea()
        .overlay(alignment: .top) { chrome }
        .safeAreaInset(edge: .bottom) { hud }
        .task { await open() }
        .onDisappear { saveTask?.cancel(); Task { await model.source?.release(volume: volume.id) } }
        .onChange(of: model.progress[volume.id]) { _, p in
            guard let p, p.device != DeviceName.current, ready, p.page != page else { return }
            remote = p
        }
        #if os(iOS)
        .statusBarHidden(true)
        #endif
    }

    private var liveAvailability: Availability {
        model.volumes[volume.series]?.first { $0.id == volume.id }?.availability ?? volume.availability
    }

    /// Which page sits on a given side depends on reading direction.
    private func tapped(_ side: Edge) {
        let forward = volume.rightToLeft ? (side == .leading) : (side == .trailing)
        step(forward ? 1 : -1, side: side)
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
                    if !editing { Task { await load() }; scheduleSave() }
                }
                // RTL volumes read right-to-left; flip the bar so it fills the same way.
                .scaleEffect(x: volume.rightToLeft ? -1 : 1, y: 1)
            } else {
                Slider(value: .constant(0), in: 0...1).disabled(true)
            }
            Text(ready ? "\(page + 1) / \(pageCount)" : "—").font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal).padding(.bottom, 8)
    }

    private func step(_ d: Int, side: Edge) {
        let n = page + d
        guard n >= 0, n < pageCount else { return }
        page = n
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
            await load()
        } catch { errorText = error.localizedDescription }
    }

    private func load() async {
        guard let source = model.source, pageCount > 0 else { return }
        do {
            let data = try await source.pageData(volume: volume.id, index: page)
            #if os(iOS)
            let px = Int(UIScreen.main.nativeBounds.width)
            #else
            let px = 2200
            #endif
            image = await Task.detached(priority: .userInitiated) { PageDecoder.decode(data, maxPixel: px) }.value
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

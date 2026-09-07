import SwiftUI
import KanpekiCore

/// Phase 1 proof, not the reader: one page decoded at a time, prev/next,
/// and the page position round-tripping through `SyncStore`.
struct ProofReaderView: View {
    @Environment(AppModel.self) private var model
    let volume: VolumeRef
    @State private var page = 0
    @State private var pageCount = 0
    @State private var image: CGImage?
    @State private var status = "Preparing…"
    @State private var ready = false
    @State private var remote: ReadingProgress?
    @State private var saveTask: Task<Void, Never>?
    @State private var errorText: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image {
                Image(image, scale: 1, label: Text("Page \(page + 1)")).resizable().aspectRatio(contentMode: .fit).ignoresSafeArea()
            } else if let errorText {
                ContentUnavailableView("Can't open", systemImage: "exclamationmark.triangle", description: Text(errorText))
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(status).foregroundStyle(.white)
                    if case .downloading(let f) = liveAvailability { ProgressView(value: f).frame(width: 200).tint(.white) }
                }
            }
        }
        .navigationTitle(volume.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        #endif
        .safeAreaInset(edge: .top) { syncBanner }
        .safeAreaInset(edge: .bottom) { hud }
        .task { await open() }
        .onDisappear { saveTask?.cancel(); Task { await model.source?.release(volume: volume.id) } }
        .onChange(of: model.progress[volume.id]) { _, p in
            // Another device moved: reflect it (only if newer than what we have shown).
            guard let p, p.device != DeviceName.current, ready, p.page != page else { return }
            remote = p
        }
    }

    private var liveAvailability: Availability {
        model.volumes[volume.series]?.first { $0.id == volume.id }?.availability ?? volume.availability
    }

    @ViewBuilder private var syncBanner: some View {
        if let r = remote {
            HStack {
                Image(systemName: "arrow.triangle.2.circlepath.icloud")
                Text("Page \(r.page + 1) on \(r.device), \(r.updatedAt.formatted(.relative(presentation: .named)))")
                Spacer()
                Button("Go") { page = r.page; remote = nil; Task { await load() } }.buttonStyle(.glassProminent)
            }
            .font(.callout).padding(.horizontal, 14).padding(.vertical, 8)
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
            .padding(.horizontal)
        }
    }

    private var hud: some View {
        GlassEffectContainer {
            HStack(spacing: 14) {
                Button { step(volume.rightToLeft ? 1 : -1) } label: { Image(systemName: "chevron.left").frame(width: 28) }
                    .buttonStyle(.glass).disabled(!ready)
                VStack(spacing: 4) {
                    Slider(value: Binding(get: { Double(page) }, set: { page = Int($0.rounded()) }), in: 0...Double(max(pageCount - 1, 0)), step: 1) { _ in
                        Task { await load(); scheduleSave() }
                    }
                    .disabled(!ready)
                    Text(ready ? "\(page + 1) / \(pageCount)" : "—").font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                }
                Button { step(volume.rightToLeft ? -1 : 1) } label: { Image(systemName: "chevron.right").frame(width: 28) }
                    .buttonStyle(.glass).disabled(!ready)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .glassEffect(.regular, in: .capsule)
        }
        .padding(.horizontal).padding(.bottom, 8)
    }

    private func step(_ d: Int) {
        let n = page + d
        guard n >= 0, n < pageCount else { return }
        page = n
        Task { await load() }
        scheduleSave()
    }

    private func open() async {
        guard let source = model.source else { return }
        do {
            status = liveAvailability == .local ? "Opening…" : "Downloading from iCloud…"
            try await source.prepare(volume: volume.id)
            // prepare() may have turned a provisional row into a real one.
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
            let decoded = await Task.detached(priority: .userInitiated) { PageDecoder.decode(data, maxPixel: px) }.value
            image = decoded
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

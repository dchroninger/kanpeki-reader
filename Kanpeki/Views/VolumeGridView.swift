import SwiftUI
import KanpekiCore

/// Cover size in the grid. Large is the original layout.
enum CoverSize: String, CaseIterable, Identifiable {
    case small, medium, large
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var symbol: String { switch self { case .small: "square.grid.4x3.fill"; case .medium: "square.grid.3x3.fill"; case .large: "square.grid.2x2.fill" } }
    var column: (min: CGFloat, max: CGFloat) { switch self { case .small: (78, 100); case .medium: (104, 134); case .large: (130, 170) } }
    var coverHeight: CGFloat { switch self { case .small: 118; case .medium: 158; case .large: 200 } }
    var spacing: CGFloat { switch self { case .small: 10; case .medium: 14; case .large: 16 } }
}

struct VolumeGridView: View {
    @Environment(AppModel.self) private var model
    let series: String
    let volumes: [VolumeRef]
    @State private var reading: VolumeRef?
    @Namespace private var zoom
    @State private var selecting = false
    @State private var selection: Set<ContentID> = []
    @AppStorage("coverSize") private var coverSizeRaw = CoverSize.large.rawValue
    private var coverSize: CoverSize { CoverSize(rawValue: coverSizeRaw) ?? .large }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: coverSize.column.min, maximum: coverSize.column.max), spacing: coverSize.spacing)], spacing: coverSize.spacing + 4) {
                ForEach(volumes) { v in
                    Button {
                        if selecting { toggle(v) } else { reading = v }
                    } label: {
                        VolumeCard(volume: v, size: coverSize, selecting: selecting, selected: selection.contains(v.id))
                    }
                        .buttonStyle(PressScaleStyle())
                        .matchedTransitionSource(id: v.id, in: zoom)
                        // Covers settle into place as they scroll in.
                        .scrollTransition(.interactive(timingCurve: .easeOut)) { content, phase in
                            content.scaleEffect(phase.isIdentity ? 1 : 0.94).opacity(phase.isIdentity ? 1 : 0.65)
                        }
                        .contextMenu {
                            if case .remote = v.availability { Button("Download", systemImage: "icloud.and.arrow.down") { model.startDownload(v) } }
                            if v.availability == .local, model.backend?.isCloud == true { Button("Remove download", systemImage: "xmark.icloud") { model.evict(v) } }
                            Button("Select", systemImage: "checkmark.circle") { selecting = true; selection = [v.id] }
                        }
                }
            }
            .padding()
        }
        .refreshable { await model.refreshAll() }
        .navigationTitle(series)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if selecting {
                    Button("Done") { withAnimation(.snappy) { selecting = false; selection = [] } }
                } else {
                    Button { withAnimation(.snappy) { selecting = true } } label: { Label("Select", systemImage: "checkmark.circle") }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Cover size", selection: $coverSizeRaw) {
                        ForEach(CoverSize.allCases) { Label($0.label, systemImage: $0.symbol).tag($0.rawValue) }
                    }
                } label: { Label("Cover size", systemImage: coverSize.symbol) }
            }
        }
        .animation(.snappy(duration: 0.25), value: coverSizeRaw)
        .safeAreaInset(edge: .bottom) { if selecting { selectionBar } }
        .readerPresentation(item: $reading) { v in
            ProofReaderView(volume: v).environment(model)
                .navigationTransition(.zoom(sourceID: v.id, in: zoom))   // cover grows into the page
        }
    }
}

extension VolumeGridView {
    private func toggle(_ v: VolumeRef) {
        withAnimation(.snappy(duration: 0.15)) { if selection.contains(v.id) { selection.remove(v.id) } else { selection.insert(v.id) } }
    }
    private var chosen: [VolumeRef] { volumes.filter { selection.contains($0.id) } }
    private var remote: [VolumeRef] { volumes.filter { if case .remote = $0.availability { true } else { false } } }

    /// Glass bar for the selection: download to keep offline, or remove.
    private var selectionBar: some View {
        HStack(spacing: 10) {
            Button("All remaining", systemImage: "checklist") { selection = Set(remote.map(\.id)) }
                .buttonStyle(.glass).disabled(remote.isEmpty)
            Spacer()
            let toGet = chosen.filter { $0.availability != .local }
            let toDrop = chosen.filter { $0.availability == .local }
            if !toDrop.isEmpty, model.backend?.isCloud == true {
                Button("Remove \(toDrop.count)", systemImage: "xmark.icloud") { model.evict(toDrop); selection = [] }.buttonStyle(.glass)
            }
            Button("Download \(toGet.count)", systemImage: "arrow.down.circle.fill") { model.keepOffline(toGet); selection = [] }
                .buttonStyle(.glassProminent).disabled(toGet.isEmpty)
        }
        .font(.subheadline)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal).padding(.bottom, 6)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

struct VolumeCard: View {
    @Environment(AppModel.self) private var model
    let volume: VolumeRef
    var size: CoverSize = .large
    var selecting = false
    var selected = false
    @State private var cover: CGImage?
    private var image: CGImage? { model.covers[volume.id] ?? cover }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let image {
                        Image(image, scale: 1, label: Text(volume.title)).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(.quaternary).overlay { Image(systemName: "book.closed").font(.largeTitle).foregroundStyle(.secondary) }
                    }
                }
                .frame(height: size.coverHeight).clipShape(RoundedRectangle(cornerRadius: size == .small ? 8 : 12))
                if selecting {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title2).symbolRenderingMode(.palette)
                        .foregroundStyle(.white, selected ? Color.accentColor : Color.black.opacity(0.35))
                        .padding(6)
                } else {
                    AvailabilityBadge(availability: volume.availability, kept: volume.keptOffline) {
                        model.startDownload(volume)     // tap the cloud to fetch
                    }
                    .padding(size == .small ? 4 : 6)
                }
            }
            .overlay { if selecting && selected { RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: 3) } }
            Text(volume.number.isEmpty ? volume.title : "Vol. \(volume.number)").font(size == .small ? .subheadline : .headline).lineLimit(1)
            HStack(spacing: 4) {
                if let p = model.progress[volume.id] {
                    Text("p.\(p.page + 1)/\(max(p.pageCount, 1))").monospacedDigit()
                    Text("· \(p.device)").lineLimit(1)
                } else if volume.pageCount > 0 {
                    Text("\(volume.pageCount) pages")
                } else {
                    Text(volume.byteSize.formatted(.byteCount(style: .file)))
                }
            }.font(size == .small ? .caption2 : .caption).foregroundStyle(.secondary)
        }
        .task(id: volume.id) {
            guard model.covers[volume.id] == nil, let src = model.source,
                  let d = try? await src.coverThumbnail(volume: volume.id) else { return }
            cover = PageDecoder.decode(d, maxPixel: 400)
        }
    }
}

struct AvailabilityBadge: View {
    let availability: Availability
    var kept = false
    var onDownload: () -> Void = {}

    /// The badge's own life cycle, driven by availability changes and taps.
    /// Rendering keys off this only, so the check can never be skipped.
    enum Phase: Equatable { case cloud, pending, downloading(Double), landed, hidden }
    @State private var phase: Phase = .hidden

    var body: some View {
        ZStack {
            switch phase {
            case .cloud:
                Button { withAnimation(.snappy) { phase = .pending }; onDownload() } label: {
                    Image(systemName: "icloud.and.arrow.down").frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
            case .pending:
                DownloadRing(progress: nil)                         // accent: asked, nothing moving yet
            case .downloading(let f):
                DownloadRing(progress: f, tint: .green)             // green: bytes flowing
            case .landed:
                Image(systemName: "checkmark").foregroundStyle(.green)
                    .transition(.symbolEffect(.appear.up))
                    .symbolEffect(.bounce, options: .nonRepeating, value: phase)
            case .hidden:
                EmptyView()
            }
        }
        .font(.caption.bold())
        .frame(width: 26, height: 26)
        .glassEffect(.regular, in: .circle)
        .opacity(phase == .hidden ? 0 : 1)
        .onAppear { phase = Self.initialPhase(availability) }
        .onChange(of: availability) { _, new in
            switch (phase, new) {
            case (.pending, .remote), (.hidden, .local), (.landed, .local): break   // nothing new
            case (_, .downloading(let f)): withAnimation(.easeOut(duration: 0.3)) { phase = .downloading(f) }
            case (.cloud, .local): phase = .hidden                                   // became local without us watching
            case (_, .local):
                withAnimation(.snappy) { phase = .landed }
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    withAnimation(.easeOut(duration: 0.6)) { if phase == .landed { phase = .hidden } }
                }
            case (_, .remote): withAnimation(.snappy) { phase = .cloud }
            case (_, .unknown): phase = .hidden
            }
        }
        .sensoryFeedback(.success, trigger: phase == .landed) { _, new in new }
    }

    private static func initialPhase(_ a: Availability) -> Phase {
        switch a {
        case .local: .hidden
        case .remote: .cloud
        case .downloading(let f): .downloading(f)
        case .unknown: .hidden
        }
    }
}

/// Buttons that give a little under the finger.
struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(duration: 0.25, bounce: 0.35), value: configuration.isPressed)
    }
}

extension View {
    /// The reader owns the whole screen: no sidebar, no sidebar toggle, no
    /// interactive swipe-back. Leaving it is the explicit back button.
    @ViewBuilder
    func readerPresentation<Item: Identifiable, Content: View>(item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        #if os(iOS)
        fullScreenCover(item: item, content: content)
        #else
        sheet(item: item) { content($0).frame(minWidth: 900, minHeight: 700) }
        #endif
    }
}

/// One ring for the whole download: spins while pending (progress nil),
/// then stops at 12 o'clock and fills as bytes arrive.
struct DownloadRing: View {
    let progress: Double?
    var tint: Color = .accentColor
    @State private var spin = false
    var body: some View {
        ZStack {
            Circle().stroke(.secondary.opacity(0.25), lineWidth: 2.5)
            Circle().trim(from: 0, to: progress.map { max($0, 0.04) } ?? 0.28)
                .stroke(tint, style: .init(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(progress == nil ? (spin ? 270 : -90) : -90))
                .animation(.easeOut(duration: 0.3), value: tint)
                .animation(progress == nil ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .easeOut(duration: 0.3), value: spin)
                .animation(.easeOut(duration: 0.3), value: progress)
        }
        .padding(5)
        .onAppear { spin = true }
        .onChange(of: progress == nil) { _, indeterminate in spin = indeterminate }
    }
}

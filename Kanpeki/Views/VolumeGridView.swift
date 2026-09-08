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
                            if case .remote = v.availability { Button("Download", systemImage: "arrow.down.circle") { model.startDownload(v) } }
                            if v.availability == .local, model.backend?.isCloud == true { Button("Remove download", systemImage: "xmark.icloud", role: .destructive) { model.evict(v) } }
                            let later = volumes.drop { $0.id != v.id }.filter { if case .remote = $0.availability { true } else { false } }
                            if later.count > 1 { Button("Download from here (\(later.count))", systemImage: "arrow.down.to.line") { model.keepOffline(Array(later)) } }
                            Divider()
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
    /// Acting on the selection ends selection mode.
    private func finishSelecting() {
        withAnimation(.snappy) { selection = []; selecting = false }
    }

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
                Button("Remove \(toDrop.count)", systemImage: "xmark.icloud") { model.evict(toDrop); finishSelecting() }.buttonStyle(.glass)
            }
            Button("Download \(toGet.count)", systemImage: "arrow.down.circle.fill") { model.keepOffline(toGet); finishSelecting() }
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

    /// One SF Symbol lives through every phase. Name changes ride magic
    /// replace (shared enclosures stay, new strokes draw in); progress is
    /// Variable Draw on the circle itself; the exit is Draw Off. Nothing here
    /// is drawn by hand.
    private var symbolName: String {
        switch phase {
        case .cloud: "icloud.and.arrow.down"
        case .pending, .downloading: "circle"
        case .landed, .hidden: "checkmark.circle"
        }
    }
    private var variableValue: Double {
        switch phase {
        case .cloud: 1
        case .pending: 0.18                     // a short arc, pulsing, while we wait for bytes
        case .downloading(let f): max(f, 0.04)
        case .landed, .hidden: 1
        }
    }
    private var tint: Color {
        switch phase {
        case .cloud: .primary
        case .pending: .accentColor
        case .downloading, .landed, .hidden: .green
        }
    }

    var body: some View {
        Image(systemName: symbolName, variableValue: variableValue)
            .symbolVariableValueMode(.draw)                                   // the ring draws with progress
            .contentTransition(.symbolEffect(.replace.magic(fallback: .downUp)))  // circle stays, check draws in
            .symbolEffect(.pulse, options: .repeating, isActive: phase == .pending)
            .symbolEffect(.bounce, options: .nonRepeating, value: phase == .landed)
            .symbolEffect(.drawOff.byLayer, isActive: phase == .hidden)       // strokes retract on the way out
            .foregroundStyle(tint)
            .font(.system(size: 15, weight: .semibold))
            .frame(width: 26, height: 26)
            .glassEffect(.regular, in: .circle)
            .contentShape(Circle())
            .onTapGesture { if phase == .cloud { withAnimation(.snappy) { phase = .pending }; onDownload() } }
            .opacity(phase == .hidden ? 0 : 1)
            .animation(.snappy, value: phase)
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
                        withAnimation(.easeOut(duration: 0.8)) { if phase == .landed { phase = .hidden } }
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


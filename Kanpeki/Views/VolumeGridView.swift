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
                        .buttonStyle(.plain)
                        .contextMenu {
                            if case .remote = v.availability { Button("Download", systemImage: "icloud.and.arrow.down") { model.startDownload(v) } }
                            if v.availability == .local, model.backend?.isCloud == true { Button("Remove download", systemImage: "xmark.icloud") { model.evict(v) } }
                            Button("Select", systemImage: "checkmark.circle") { selecting = true; selection = [v.id] }
                        }
                }
            }
            .padding()
        }
        .navigationTitle(series)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(selecting ? "Done" : "Select") { withAnimation(.snappy) { selecting.toggle(); if !selecting { selection = [] } } }
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
        .readerPresentation(item: $reading) { ProofReaderView(volume: $0).environment(model) }
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
    var body: some View {
        Group {
            switch availability {
            case .local:
                // Kept-offline volumes get the solid mark; cached ones the plain check.
                Image(systemName: kept ? "arrow.down.circle.fill" : "checkmark").foregroundStyle(.green)
            case .remote:
                Button(action: onDownload) { Image(systemName: "icloud.and.arrow.down").frame(width: 26, height: 26) }
                    .buttonStyle(.plain)
            case .downloading(let f): ProgressView(value: f).progressViewStyle(.circular).controlSize(.small)
            case .unknown: Image(systemName: "questionmark")
            }
        }
        .font(.caption.bold())
        .frame(width: 26, height: 26)
        .glassEffect(.regular, in: .circle)
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

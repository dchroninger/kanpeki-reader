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
    @AppStorage("coverSize") private var coverSizeRaw = CoverSize.large.rawValue
    private var coverSize: CoverSize { CoverSize(rawValue: coverSizeRaw) ?? .large }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: coverSize.column.min, maximum: coverSize.column.max), spacing: coverSize.spacing)], spacing: coverSize.spacing + 4) {
                ForEach(volumes) { v in
                    Button { reading = v } label: { VolumeCard(volume: v, size: coverSize) }
                        .buttonStyle(PressScaleStyle())
                        .matchedTransitionSource(id: v.id, in: zoom)
                        // Covers settle into place as they scroll in.
                        .scrollTransition(.interactive(timingCurve: .easeOut)) { content, phase in
                            content.scaleEffect(phase.isIdentity ? 1 : 0.94).opacity(phase.isIdentity ? 1 : 0.65)
                        }
                        .contextMenu {
                            if case .remote = v.availability { Button("Download", systemImage: "icloud.and.arrow.down") { model.startDownload(v) } }
                            if v.availability == .local, model.backend?.isCloud == true { Button("Remove download", systemImage: "xmark.icloud") { model.evict(v) } }
                        }
                }
            }
            .padding()
        }
        .navigationTitle(series)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Cover size", selection: $coverSizeRaw) {
                        ForEach(CoverSize.allCases) { Label($0.label, systemImage: $0.symbol).tag($0.rawValue) }
                    }
                } label: { Label("Cover size", systemImage: coverSize.symbol) }
            }
        }
        .animation(.snappy(duration: 0.25), value: coverSizeRaw)
        .readerPresentation(item: $reading) { v in
            ProofReaderView(volume: v).environment(model)
                .navigationTransition(.zoom(sourceID: v.id, in: zoom))   // cover grows into the page
        }
    }
}

struct VolumeCard: View {
    @Environment(AppModel.self) private var model
    let volume: VolumeRef
    var size: CoverSize = .large
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
                AvailabilityBadge(availability: volume.availability).padding(size == .small ? 4 : 6)
            }
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
    private var isLocal: Bool { availability == .local }
    var body: some View {
        ZStack {
            switch availability {
            case .local:
                Image(systemName: "checkmark").foregroundStyle(.green)
                    .symbolEffect(.bounce, value: isLocal)           // one bounce when the download lands
            case .remote:
                Image(systemName: "icloud.and.arrow.down")
            case .downloading(let f):
                Circle().stroke(.secondary.opacity(0.25), lineWidth: 2.5)
                Circle().trim(from: 0, to: max(f, 0.03)).stroke(Color.accentColor, style: .init(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.3), value: f)
                    .padding(5)
            case .unknown:
                Image(systemName: "questionmark")
            }
        }
        .font(.caption.bold())
        .frame(width: 26, height: 26)
        .glassEffect(.regular, in: .circle)
        .contentTransition(.symbolEffect(.replace))
        .animation(.snappy, value: availability)
        .sensoryFeedback(.success, trigger: isLocal) { old, new in !old && new }
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

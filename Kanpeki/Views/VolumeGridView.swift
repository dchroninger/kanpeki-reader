import SwiftUI
import KanpekiCore

struct VolumeGridView: View {
    @Environment(AppModel.self) private var model
    let series: String
    let volumes: [VolumeRef]
    @State private var reading: VolumeRef?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 170), spacing: 16)], spacing: 20) {
                ForEach(volumes) { v in
                    Button { reading = v } label: { VolumeCard(volume: v) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if case .remote = v.availability { Button("Download", systemImage: "icloud.and.arrow.down") { model.startDownload(v) } }
                            if v.availability == .local, model.backend?.isCloud == true { Button("Remove download", systemImage: "xmark.icloud") { model.evict(v) } }
                        }
                }
            }
            .padding()
        }
        .navigationTitle(series)
        .readerPresentation(item: $reading) { ProofReaderView(volume: $0).environment(model) }
    }
}

struct VolumeCard: View {
    @Environment(AppModel.self) private var model
    let volume: VolumeRef
    @State private var cover: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let cover {
                        Image(cover, scale: 1, label: Text(volume.title)).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(.quaternary).overlay { Image(systemName: "book.closed").font(.largeTitle).foregroundStyle(.secondary) }
                    }
                }
                .frame(height: 200).clipShape(RoundedRectangle(cornerRadius: 12))
                AvailabilityBadge(availability: volume.availability).padding(6)
            }
            Text(volume.number.isEmpty ? volume.title : "Vol. \(volume.number)").font(.headline).lineLimit(1)
            HStack(spacing: 4) {
                if let p = model.progress[volume.id] {
                    Text("p.\(p.page + 1)/\(max(p.pageCount, 1))").monospacedDigit()
                    Text("· \(p.device)").lineLimit(1)
                } else if volume.pageCount > 0 {
                    Text("\(volume.pageCount) pages")
                } else {
                    Text(volume.byteSize.formatted(.byteCount(style: .file)))
                }
            }.font(.caption).foregroundStyle(.secondary)
        }
        .task(id: volume.id) {
            guard let src = model.source, let d = try? await src.coverThumbnail(volume: volume.id) else { return }
            cover = PageDecoder.decode(d, maxPixel: 400)
        }
    }
}

struct AvailabilityBadge: View {
    let availability: Availability
    var body: some View {
        Group {
            switch availability {
            case .local: Image(systemName: "checkmark").foregroundStyle(.green)
            case .remote: Image(systemName: "icloud.and.arrow.down")
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

import SwiftUI
import KanpekiCore

struct VolumeGridView: View {
    @Environment(AppModel.self) private var model
    let series: String
    let volumes: [VolumeRef]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 170), spacing: 16)], spacing: 20) {
                ForEach(volumes) { v in
                    NavigationLink(value: v) { VolumeCard(volume: v) }
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
        .navigationDestination(for: VolumeRef.self) { ProofReaderView(volume: $0) }
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

import SwiftUI
import KanpekiCore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedSeries: String?
    @State private var showStorage = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedSeries) {
                ForEach(model.series) { s in
                    NavigationLink(value: s.name) {
                        HStack {
                            Text(s.name).lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 8)
                            Text("\(s.volumeCount)").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Kanpeki")
            .overlay { if model.series.isEmpty { EmptyLibraryView() } }
            .toolbar {
                ToolbarItem { Button { showStorage = true } label: { Label("Storage & Sync", systemImage: "internaldrive") } }
                ToolbarItem { Button { model.monitor?.refresh(); Task { await model.refreshSync() } } label: { Label("Refresh", systemImage: "arrow.clockwise") } }
            }
            .safeAreaInset(edge: .bottom) { StatusChip() }
        } detail: {
            NavigationStack {
                if let s = selectedSeries, let vols = model.volumes[s] {
                    VolumeGridView(series: s, volumes: vols)
                } else {
                    ContentUnavailableView("Select a series", systemImage: "books.vertical")
                }
            }
        }
        .sheet(isPresented: $showStorage) { StorageView() }
    }
}

struct StatusChip: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: model.backend?.isCloud == true ? "icloud" : "folder")
            if let p = model.scanProgress {
                ProgressView(value: Double(p.done), total: Double(max(p.total, 1))).frame(width: 60)
                Text("Scanning \(p.done)/\(p.total)")
            } else {
                Text(model.backend?.label ?? "Starting…")
                Text("·").foregroundStyle(.tertiary)
                Text(model.localBytes.formatted(.byteCount(style: .file))).monospacedDigit()
                Text("local")
            }
            Image(systemName: model.cloudSync != nil ? "checkmark.icloud" : "xmark.icloud")
                .foregroundStyle(model.cloudSync != nil ? .green : .orange)
                .help(model.cloudSync != nil ? "Progress syncs via CloudKit" : "No iCloud account: progress stays on this device")
        }
        .font(.footnote)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .padding(.bottom, 6)
    }
}

struct EmptyLibraryView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        ContentUnavailableView {
            Label("No volumes yet", systemImage: "tray")
        } description: {
            Text(model.backend?.isCloud == true
                 ? "Drop .cbz files into the Kanpeki folder in iCloud Drive on any device."
                 : "iCloud Drive isn't available here. Files in the app's Documents folder are used instead.")
        } actions: {
            GlassEffectContainer {
                HStack {
                    Button("Reveal folder", systemImage: "folder") { model.revealInFiles() }.buttonStyle(.glass)
                    Button("Add sample volumes", systemImage: "sparkles") { Task { await model.addSampleVolumes() } }.buttonStyle(.glassProminent)
                }
            }
        }
    }
}

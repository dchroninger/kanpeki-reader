import SwiftUI
import KanpekiCore

struct StorageView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    private let caps: [Int64] = [256, 512, 1024, 2048, 4096, 8192].map { $0 * 1024 * 1024 }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section("Library") {
                    LabeledContent("Source", value: model.backend?.label ?? "—")
                    LabeledContent("Folder") { Text(model.backend?.rootURL.path ?? "—").font(.caption).textSelection(.enabled).lineLimit(3) }
                    LabeledContent("Archives", value: "\(model.items.count)")
                    if let s = model.scanSummary {
                        LabeledContent("Last scan", value: "\(s.scanned) scanned · \(s.provisional) remote · \(s.unchanged) unchanged · \(s.removed) removed · \(s.failed) failed")
                    }
                    Button("Reveal in \(revealTarget)", systemImage: "folder") { model.revealInFiles() }
                    Button("Rebuild cache from files", systemImage: "arrow.counterclockwise") { Task { await model.rebuildCache() } }
                        .disabled(model.isScanning)
                    Button("Add sample volumes", systemImage: "sparkles") { Task { await model.addSampleVolumes() } }
                }
                Section("On-device storage") {
                    LabeledContent("Local now", value: model.localBytes.formatted(.byteCount(style: .file)))
                    if model.automaticEvictionSupported {
                        Picker("Keep at most", selection: $model.byteCap) {
                            ForEach(caps, id: \.self) { Text($0.formatted(.byteCount(style: .file))).tag($0) }
                        }
                    } else {
                        Text("Automatic eviction is off on the Mac; iCloud Drive's \"Optimize Mac Storage\" governs local copies.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Download everything", systemImage: "icloud.and.arrow.down") { model.downloadAll() }
                        .disabled(model.backend?.isCloud != true || model.items.allSatisfy(\.isLocal))
                    Button("Evict everything now", systemImage: "xmark.icloud", role: .destructive) { model.evictAll() }
                        .disabled(model.backend?.isCloud != true)
                    if !model.evictions.isEmpty {
                        DisclosureGroup("Eviction log (\(model.evictions.count))") {
                            ForEach(model.evictions.suffix(20).reversed(), id: \.self) { Text($0).font(.caption) }
                        }
                    }
                }
                Section("Reading position sync") {
                    LabeledContent("Store", value: model.cloudSync != nil ? "CloudKit private database" : "This device only")
                    LabeledContent("iCloud account", value: model.accountState)
                    if let t = model.lastSync { LabeledContent("Last refresh", value: t.formatted(date: .omitted, time: .standard)) }
                    if let e = model.syncError { Text(e).foregroundStyle(.red).font(.caption) }
                    LabeledContent("Positions known", value: "\(model.progress.count)")
                    Button("Refresh now", systemImage: "arrow.clockwise") { Task { await model.refreshSync() } }
                }
                if let e = model.startupError {
                    Section("Last error") { Text(e).font(.caption).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Storage & Sync")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 560)
        #endif
    }

    private var revealTarget: String {
        #if os(macOS)
        "Finder"
        #else
        "Files"
        #endif
    }
}

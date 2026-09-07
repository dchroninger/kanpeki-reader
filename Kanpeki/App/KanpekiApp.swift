import SwiftUI
import KanpekiCore

@main
struct KanpekiApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .task { await model.start() }
                .onChange(of: phase) { _, p in
                    if p == .active { Task { await model.refreshSync(); model.monitor?.refresh() } }
                }
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 720)
        #endif
    }
}

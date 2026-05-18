import SwiftUI

@main
struct MaycastStudioApp: App {
    @State private var store = EpisodeStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .frame(minWidth: 640, minHeight: 420)
        }
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("Episode") {
                Button("Open…") { store.openWithPanel() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Close") { store.close() }
                    .keyboardShortcut("w", modifiers: .command)
                    .disabled(store.bundle == nil)
            }
        }
    }
}

import SwiftUI

@main
struct MaycastStudioApp: App {
    @State private var store = EpisodeStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .frame(minWidth: 640, minHeight: 420)
                .sheet(isPresented: $store.isShowingHistory) {
                    if let bundle = store.bundle {
                        HistorySheet(bundle: bundle)
                    }
                }
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { store.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!store.canUndo)
                Button("Redo") { store.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!store.canRedo)
            }
            CommandMenu("Episode") {
                Button("Open…") { store.openWithPanel() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Close") { store.close() }
                    .keyboardShortcut("w", modifiers: .command)
                    .disabled(store.bundle == nil)
                Divider()
                Button("Show History…") { store.isShowingHistory = true }
                    .keyboardShortcut("h", modifiers: [.command, .option])
                    .disabled(store.bundle == nil)
            }
        }
    }
}

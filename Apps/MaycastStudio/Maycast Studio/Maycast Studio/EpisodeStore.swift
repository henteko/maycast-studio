import SwiftUI
import MaycastCore

@MainActor
@Observable
final class EpisodeStore {
    var bundle: EpisodeBundle?
    var errorMessage: String?
    var isShowingHistory: Bool = false

    func openWithPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a Maycast Episode bundle (.maycast)"
        panel.prompt = "Open"
        if panel.runModal() == .OK, let url = panel.url {
            open(at: url)
        }
    }

    func open(at url: URL) {
        do {
            bundle = try EpisodeBundle.open(at: url)
            errorMessage = nil
        } catch {
            bundle = nil
            errorMessage = String(describing: error)
        }
    }

    func close() {
        bundle = nil
        errorMessage = nil
    }

    // MARK: - Undo / Redo

    var canUndo: Bool { bundle?.canUndo ?? false }
    var canRedo: Bool { bundle?.canRedo ?? false }

    func undo() {
        guard var b = bundle else { return }
        do {
            _ = try b.undo()
            // Reopen from disk to ensure all derived state (arrangements,
            // transcripts, ...) is consistent with the new `current`.
            bundle = try EpisodeBundle.open(at: b.url)
        } catch {
            errorMessage = "Undo failed: \(error)"
        }
    }

    func redo() {
        guard var b = bundle else { return }
        do {
            _ = try b.redo()
            bundle = try EpisodeBundle.open(at: b.url)
        } catch {
            errorMessage = "Redo failed: \(error)"
        }
    }
}

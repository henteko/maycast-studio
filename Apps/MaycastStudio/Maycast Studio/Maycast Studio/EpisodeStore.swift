import SwiftUI
import MaycastCore

@MainActor
@Observable
final class EpisodeStore {
    var bundle: EpisodeBundle?
    var errorMessage: String?

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
}

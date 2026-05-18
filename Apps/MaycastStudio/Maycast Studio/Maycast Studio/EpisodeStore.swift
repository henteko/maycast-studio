import SwiftUI
import AppKit
import os
import MaycastCore

@MainActor
@Observable
final class EpisodeStore {
    var bundle: EpisodeBundle?
    var errorMessage: String?
    var isShowingHistory: Bool = false
    /// Recently opened / created episodes — loaded from UserDefaults on init,
    /// saved on every mutation. Each entry holds a security-scoped bookmark
    /// so the app can reopen the bundle across launches under App Sandbox.
    var recents: [RecentEpisode]
    /// Human-readable description of the current Episode-creation step, used
    /// by the "Creating…" sheet so the user can tell whether the app is
    /// copying audio, reading frames, etc. Nil when not creating.
    var createStage: String?

    private let createLog = Logger(subsystem: "MaycastStudio", category: "Create")

    init() {
        self.recents = RecentsStore.load()
    }

    /// Update `createStage` on the MainActor and emit an os-log + stdout
    /// trace so the user sees the same string in Xcode's console.
    private func setCreateStage(_ stage: String?) {
        self.createStage = stage
        if let stage {
            createLog.info("[Create] \(stage, privacy: .public)")
            print("[Create] \(stage)")
        }
    }

    // MARK: - Open

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
            let opened = try EpisodeBundle.open(at: url)
            bundle = opened
            errorMessage = nil
            addToRecents(bundleURL: url, showName: showName(in: opened))
        } catch {
            bundle = nil
            errorMessage = String(describing: error)
        }
    }

    func openRecent(_ recent: RecentEpisode) {
        guard let url = RecentsStore.resolveURL(for: recent) else {
            errorMessage = "Could not locate \(recent.absolutePath). Was the bundle moved or deleted?"
            return
        }
        open(at: url)
    }

    func close() {
        bundle = nil
        errorMessage = nil
    }

    // MARK: - Recents

    func forgetRecent(_ recent: RecentEpisode) {
        recents.removeAll { $0.id == recent.id }
        RecentsStore.save(recents)
    }

    private func addToRecents(bundleURL: URL, showName: String?) {
        recents = RecentsStore.upsert(bundleURL: bundleURL, showName: showName, in: recents)
        RecentsStore.save(recents)
    }

    private func showName(in bundle: EpisodeBundle) -> String? {
        guard let showRel = bundle.episode.show else { return nil }
        let resolved = URL(fileURLWithPath: showRel, relativeTo: bundle.url).standardizedFileURL
        return resolved.deletingPathExtension().lastPathComponent
    }

    // MARK: - Creation

    /// Create a new Episode bundle on disk (optionally with a Show attached)
    /// and import any speakers the user supplied. Returns nil on success; an
    /// error message string on failure.
    ///
    /// The heavy I/O (`EpisodeBundle.create`, per-speaker `importTrack` which
    /// reads + transcodes the source audio) runs on a detached background
    /// task so the MainActor — and therefore the "Creating…" UI — stays
    /// responsive. Speakers are imported sequentially; if a later import
    /// fails, the bundle and any tracks already imported remain on disk so
    /// the user can inspect or finish manually.
    @discardableResult
    func createEpisode(form: NewEpisodeForm) async -> String? {
        let bundleURL = URL(fileURLWithPath: form.bundlePath)
        let showPath = form.attachedShowPath
        let importable = form.importableSpeakers
        setCreateStage("Starting (bundle: \(bundleURL.lastPathComponent))")

        // `@Sendable` pump so the detached worker can update the UI stage
        // string without touching MainActor state directly.
        let store = self
        let progress: @Sendable (String) -> Void = { stage in
            Task { @MainActor in store.setCreateStage(stage) }
        }

        do {
            try await Task.detached(priority: .userInitiated) {
                var show: ShowBundle? = nil
                if let showPath {
                    progress("Opening Show \(URL(fileURLWithPath: showPath).lastPathComponent)…")
                    show = try ShowBundle.open(at: URL(fileURLWithPath: showPath))
                }
                progress("Creating bundle at \(bundleURL.lastPathComponent)…")
                var bundle = try EpisodeBundle.create(at: bundleURL, show: show)
                progress("Bundle created. \(importable.count) speaker(s) to import.")

                for (idx, sp) in importable.enumerated() {
                    let id = sp.trackID.trimmingCharacters(in: .whitespacesAndNewlines)
                    let audioURL = URL(fileURLWithPath: sp.audioPath ?? "")
                    let fileSize = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int) ?? 0
                    let sizeMB = Double(fileSize) / (1024 * 1024)
                    progress(String(
                        format: "Importing speaker %d/%d: %@ ← %@ (%.1f MB)",
                        idx + 1, importable.count, id, audioURL.lastPathComponent, sizeMB
                    ))
                    let start = Date()
                    _ = try bundle.importTrack(from: audioURL, as: id)
                    let elapsed = Date().timeIntervalSince(start)
                    progress(String(format: "Imported %@ in %.2fs", id, elapsed))
                }
                progress("Finalising…")
            }.value
        } catch {
            createLog.error("[Create] FAILED: \(String(describing: error), privacy: .public)")
            print("[Create] FAILED: \(error)")
            setCreateStage(nil)
            return "Failed to create Episode: \(error)"
        }
        open(at: bundleURL)
        setCreateStage(nil)
        return nil
    }

    /// Create a new Show bundle on disk, optionally setting intro / outro
    /// assets. Returns nil on success; an error message string on failure.
    /// File copies happen on a detached task so the UI doesn't freeze on big
    /// assets.
    @discardableResult
    func createShow(form: NewShowForm) async -> String? {
        let bundleURL = URL(fileURLWithPath: form.bundlePath)
        let displayNameValue = form.displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let introPath = form.introPath
        let outroPath = form.outroPath
        do {
            try await Task.detached(priority: .userInitiated) {
                var show = try ShowBundle.create(
                    at: bundleURL,
                    name: displayNameValue.isEmpty ? nil : displayNameValue
                )
                try show.setAssets(
                    intro: introPath.map { URL(fileURLWithPath: $0) },
                    outro: outroPath.map { URL(fileURLWithPath: $0) },
                    bgm: nil
                )
            }.value
        } catch {
            return "Failed to create Show: \(error)"
        }
        return nil
    }

    // MARK: - Panel helpers

    /// `NSSavePanel` for choosing where to create a new bundle directory.
    /// Returns the chosen URL or nil if cancelled.
    func pickBundleDestination(suggestedName: String, extensionTag: String, prompt: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = []   // user-typed extension
        panel.canCreateDirectories = true
        panel.message = prompt
        panel.prompt = "Create"
        guard panel.runModal() == .OK, var url = panel.url else { return nil }
        // Ensure the chosen URL ends with the requested extension.
        if url.pathExtension.lowercased() != extensionTag.lowercased() {
            url = url.appendingPathExtension(extensionTag)
        }
        return url
    }

    /// `NSOpenPanel` for picking an existing `.maycastshow` directory.
    func pickExistingShowBundle() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a Maycast Show bundle (.maycastshow)"
        panel.prompt = "Select"
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// `NSOpenPanel` for picking an existing audio file (intro / outro / etc).
    func pickAudioFile(prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = prompt
        panel.prompt = "Select"
        // Restrict to audio types AVFoundation can read.
        panel.allowedContentTypes = [.audio]
        return panel.runModal() == .OK ? panel.url : nil
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

// `UTType.audio` requires UniformTypeIdentifiers.
import UniformTypeIdentifiers

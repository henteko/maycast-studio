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
    /// Shows discovered in the Maycast library, offered in the New Episode
    /// sheet for one-click attach (no file panel). Refreshed when the sheet is
    /// presented via `refreshAvailableShows()`.
    var availableShows: [ShowChoice] = []

    private let createLog = Logger(subsystem: "MaycastStudio", category: "Create")

    init() {
        self.recents = RecentsStore.load()
        // Recover Shows / Episodes orphaned in the old sandbox container when
        // the App Sandbox was turned off (one-time, no-op once migrated).
        MaycastLibrary.migrateLegacySandboxLibraryIfNeeded()
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
        MaycastLibrary.ensure()
        let showPath = form.attachedShowPath

        // Episodes attached to a Show live inside it (`<show>/episodes/…`);
        // standalone Episodes live flat in the library.
        let bundleURL: URL
        let locationDescription: String
        if let showPath {
            bundleURL = MaycastLibrary.episodeURL(
                inShowAt: URL(fileURLWithPath: showPath), forName: form.name
            )
            locationDescription = form.attachedShowName ?? "the attached Show"
        } else {
            bundleURL = MaycastLibrary.episodeURL(forName: form.name)
            locationDescription = "your library"
        }
        if FileManager.default.fileExists(atPath: bundleURL.path) {
            return "An Episode named “\(form.derivedEpisodeID)” already exists in \(locationDescription). Choose a different name."
        }
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
        MaycastLibrary.ensure()
        let displayNameValue = form.displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bundleURL = MaycastLibrary.showURL(forName: displayNameValue)
        if FileManager.default.fileExists(atPath: bundleURL.path) {
            return "A Show named “\(form.resolvedDisplayName)” already exists in your library."
        }
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

    // MARK: - Show library

    /// Rescan the library for Shows. Cheap (library-local, no Powerbox), so it's
    /// fine to call each time the New Episode sheet opens. We scan the whole
    /// library root recursively so any Show folder already sitting in the
    /// library — in `Shows/`, at the root, or nested, and with or without the
    /// `.maycastshow` extension — is offered automatically.
    func refreshAvailableShows() {
        MaycastLibrary.ensure()
        availableShows = ShowBundle.discover(in: MaycastLibrary.rootURL, recursive: true)
            .map { ShowChoice(name: $0.name, path: $0.url.path) }
    }

    /// Validate a `.maycastshow` dropped from Finder and turn it into a
    /// `ShowChoice` to attach. Returns nil (and sets `errorMessage`) if the
    /// dropped item isn't a readable Show bundle. The drop itself grants the
    /// sandbox access needed to read the manifest and, later, snapshot its
    /// assets at Episode-create time.
    func showChoice(forDroppedShowAt url: URL) -> ShowChoice? {
        guard url.pathExtension.lowercased() == MaycastCoreInfo.showBundleExtension else {
            errorMessage = "Drop a .maycastshow bundle (got \(url.lastPathComponent))."
            return nil
        }
        guard let bundle = try? ShowBundle.open(at: url) else {
            errorMessage = "Couldn't read the Show at \(url.path)."
            return nil
        }
        return ShowChoice(name: bundle.show.name, path: url.path)
    }

    // MARK: - Panel helpers

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
    func pickAudioFile(prompt: String, allowVideo: Bool = false) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = prompt
        panel.prompt = "Select"
        // Restrict to audio (and, for speakers, video) types we can read.
        panel.allowedContentTypes = allowVideo ? [.audio, .movie] : [.audio]
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

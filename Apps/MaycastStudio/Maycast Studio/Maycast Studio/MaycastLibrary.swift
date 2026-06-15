import Foundation
import MaycastCore

/// The Maycast "library" — a folder inside the app's sandbox container where
/// Shows (and, later, Episodes) live. Because it sits in the container, the
/// app can read and write it **without** the file panel / Powerbox or any
/// security-scoped bookmark, which is the whole point: scanning it for Shows
/// is fast and never blocks on the system open/save panel.
///
/// Trade-off (chosen deliberately): the files live deep under
/// `~/Library/Containers/<bundle-id>/Data/Library/Application Support/Maycast`
/// and are not obvious in Finder. Surfaces that need to reveal them should use
/// `NSWorkspace.activateFileViewerSelecting`.
enum MaycastLibrary {
    /// Root library directory. Falls back to a temp dir only if the container's
    /// Application Support is somehow unavailable (should not happen in
    /// practice).
    static var rootURL: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Maycast", isDirectory: true)
    }

    /// Directory holding the user's `.maycastshow` bundles.
    static var showsURL: URL {
        rootURL.appendingPathComponent("Shows", isDirectory: true)
    }

    /// Directory holding the user's `.maycast` Episode bundles.
    static var episodesURL: URL {
        rootURL.appendingPathComponent("Episodes", isDirectory: true)
    }

    /// Ensure the library directories exist. Idempotent; safe to call on every
    /// access. Returns false only if creation failed.
    @discardableResult
    static func ensure() -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: showsURL, withIntermediateDirectories: true)
            try fm.createDirectory(at: episodesURL, withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Legacy sandbox migration

    /// `UserDefaults` flag so the (cheap but disk-touching) migration only ever
    /// runs to completion once.
    private static let legacyMigrationDoneKey = "MaycastLibrary.legacySandboxMigrationDone"

    /// Path the library lived at while the app was sandboxed:
    /// `~/Library/Containers/<bundleID>/Data/Library/Application Support/Maycast`.
    /// Returns nil if we can't resolve the bundle id or it equals the active
    /// library (i.e. we're still sandboxed — nothing to migrate from).
    private static var legacySandboxRootURL: URL? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        let container = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers", isDirectory: true)
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("Data/Library/Application Support/Maycast", isDirectory: true)
        if container.standardizedFileURL == rootURL.standardizedFileURL { return nil }
        return container
    }

    /// One-time migration. Turning the App Sandbox off moved Application Support
    /// from the sandbox container to the real `~/Library/Application Support`,
    /// orphaning any Shows / Episodes created while sandboxed. If the active
    /// library is still empty and the legacy container library has content,
    /// move `Shows/` and `Episodes/` across so existing work reappears.
    ///
    /// Safe by construction: it only runs when the destination is empty, moves
    /// per-entry (never overwriting), and records a flag so it won't run again.
    static func migrateLegacySandboxLibraryIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: legacyMigrationDoneKey) else { return }
        guard let legacyRoot = legacySandboxRootURL else { return }

        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyRoot.path) else {
            // No legacy library at all — nothing to do, and never again.
            defaults.set(true, forKey: legacyMigrationDoneKey)
            return
        }

        ensure()
        // Only migrate into an empty library, so we never clobber newer work.
        guard isEmpty(showsURL), isEmpty(episodesURL) else {
            defaults.set(true, forKey: legacyMigrationDoneKey)
            return
        }

        for sub in ["Shows", "Episodes"] {
            let from = legacyRoot.appendingPathComponent(sub, isDirectory: true)
            let to = rootURL.appendingPathComponent(sub, isDirectory: true)
            guard let entries = try? fm.contentsOfDirectory(
                at: from, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            try? fm.createDirectory(at: to, withIntermediateDirectories: true)
            for entry in entries {
                let dest = to.appendingPathComponent(entry.lastPathComponent)
                guard !fm.fileExists(atPath: dest.path) else { continue }
                try? fm.moveItem(at: entry, to: dest)
            }
        }
        defaults.set(true, forKey: legacyMigrationDoneKey)
    }

    /// True when `url` is missing or holds no visible entries.
    private static func isEmpty(_ url: URL) -> Bool {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return entries.isEmpty
    }

    // MARK: - Name → bundle URL

    /// Library URL for a new Episode bundle with the given user-entered name.
    static func episodeURL(forName name: String) -> URL {
        episodesURL.appendingPathComponent(
            sanitized(name) + "." + MaycastCoreInfo.episodeBundleExtension
        )
    }

    /// URL for an Episode that belongs to a Show — created inside the Show's
    /// `episodes/` directory, per the architecture's Show→Episode containment.
    /// (The Show may live outside the library, e.g. dropped from Finder.)
    static func episodeURL(inShowAt showURL: URL, forName name: String) -> URL {
        showURL
            .appendingPathComponent("episodes", isDirectory: true)
            .appendingPathComponent(
                sanitized(name) + "." + MaycastCoreInfo.episodeBundleExtension
            )
    }

    /// Library URL for a new Show bundle with the given user-entered name.
    static func showURL(forName name: String) -> URL {
        showsURL.appendingPathComponent(
            sanitized(name) + "." + MaycastCoreInfo.showBundleExtension
        )
    }

    /// Turn a user-entered name into a safe single path component: trim, and
    /// replace the filename-illegal `/` and `:` with `-`. Empty → "untitled".
    static func sanitized(_ name: String) -> String {
        let cleaned = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return cleaned.isEmpty ? "untitled" : cleaned
    }
}

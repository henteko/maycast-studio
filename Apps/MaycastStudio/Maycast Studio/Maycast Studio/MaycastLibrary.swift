import Foundation

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

    /// Ensure the library directories exist. Idempotent; safe to call on every
    /// access. Returns false only if creation failed.
    @discardableResult
    static func ensure() -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: showsURL, withIntermediateDirectories: true
            )
            return true
        } catch {
            return false
        }
    }
}

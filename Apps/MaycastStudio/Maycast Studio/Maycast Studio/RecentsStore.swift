import Foundation

/// UserDefaults-backed list of recently opened / created episodes. Each entry
/// carries a security-scoped bookmark so the app can reopen the bundle on
/// subsequent launches even under App Sandbox.
enum RecentsStore {
    private static let defaultsKey = "maycast.recents.v1"
    private static let maxEntries = 20

    // MARK: - Load / save

    static func load() -> [RecentEpisode] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return [] }
        do {
            return try JSONDecoder().decode([RecentEpisode].self, from: data)
        } catch {
            // Corrupt store — discard rather than crash.
            return []
        }
    }

    static func save(_ recents: [RecentEpisode]) {
        do {
            let data = try JSONEncoder().encode(recents)
            UserDefaults.standard.set(data, forKey: defaultsKey)
        } catch {
            // Nothing actionable — log and move on.
            print("[RecentsStore] save failed: \(error)")
        }
    }

    // MARK: - Mutation helpers

    /// Add or move-to-top an entry derived from the given bundle URL. Returns
    /// the resulting list (truncated to `maxEntries`).
    static func upsert(
        bundleURL: URL,
        showName: String?,
        in recents: [RecentEpisode]
    ) -> [RecentEpisode] {
        var copy = recents
        copy.removeAll { $0.absolutePath == bundleURL.path }

        let displayName = bundleURL.deletingPathExtension().lastPathComponent
        let bookmark = try? bundleURL.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let entry = RecentEpisode(
            displayName: displayName.isEmpty ? "untitled" : displayName,
            absolutePath: bundleURL.path,
            lastOpened: Date(),
            showName: showName,
            bookmark: bookmark
        )
        copy.insert(entry, at: 0)
        if copy.count > maxEntries {
            copy = Array(copy.prefix(maxEntries))
        }
        return copy
    }

    /// Resolve an entry's stored bookmark back into a URL, restarting the
    /// security scope. Returns nil if the file moved / was deleted / the
    /// bookmark is malformed.
    ///
    /// The caller is responsible for `stopAccessingSecurityScopedResource()`
    /// on the returned URL when finished — but Maycast's typical access pattern
    /// is "open the bundle and keep the access for the lifetime of the
    /// session", so a single start at open time is fine.
    static func resolveURL(for recent: RecentEpisode) -> URL? {
        // Fast path: file exists at the stored absolute path (no sandbox
        // restriction in dev / non-sandboxed builds).
        let plain = URL(fileURLWithPath: recent.absolutePath)
        if FileManager.default.fileExists(atPath: plain.path), recent.bookmark == nil {
            return plain
        }

        guard let bookmark = recent.bookmark else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        return url
    }
}

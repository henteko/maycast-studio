import Foundation

/// A `.maycastshow` bundle found while scanning a directory — its display name
/// plus the bundle URL. Lightweight so callers can list Shows without opening
/// every bundle's full manifest into memory.
public struct DiscoveredShow: Sendable, Equatable {
    public let name: String
    public let url: URL

    public init(name: String, url: URL) {
        self.name = name
        self.url = url
    }
}

/// Represents a `<name>.maycastshow` bundle on disk.
public struct ShowBundle: Sendable {
    public let url: URL
    public var show: Show

    public init(url: URL, show: Show) {
        self.url = url
        self.show = show
    }

    // MARK: - Paths

    public var manifestURL: URL {
        url.appendingPathComponent(MaycastCoreInfo.showManifestFileName)
    }

    public var assetsDirectoryURL: URL {
        url.appendingPathComponent("assets", isDirectory: true)
    }

    public var episodesDirectoryURL: URL {
        url.appendingPathComponent("episodes", isDirectory: true)
    }

    // MARK: - Create / Open / Save

    public static func create(at url: URL, name: String? = nil) throws -> ShowBundle {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            throw MaycastError.bundleAlreadyExists(url)
        }
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            try fm.createDirectory(at: url.appendingPathComponent("assets", isDirectory: true),
                                   withIntermediateDirectories: true)
            try fm.createDirectory(at: url.appendingPathComponent("episodes", isDirectory: true),
                                   withIntermediateDirectories: true)
        } catch {
            throw MaycastError.ioError(url, underlying: error)
        }

        let derivedName = name ?? url.deletingPathExtension().lastPathComponent
        let show = Show(name: derivedName)
        let bundle = ShowBundle(url: url, show: show)
        try bundle.save()
        return bundle
    }

    public static func open(at url: URL) throws -> ShowBundle {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            throw MaycastError.bundleNotFound(url)
        }
        let manifest = url.appendingPathComponent(MaycastCoreInfo.showManifestFileName)
        guard fm.fileExists(atPath: manifest.path) else {
            throw MaycastError.manifestNotFound(manifest)
        }
        let show = try JSONCoders.decode(Show.self, from: manifest)
        return ShowBundle(url: url, show: show)
    }

    public func save() throws {
        try JSONCoders.encode(show, to: manifestURL)
    }

    // MARK: - Asset management

    /// Copy the given files into the show's `assets/` directory and update `show.json`.
    /// Any provided URL is copied; nil values leave the existing setting untouched.
    public mutating func setAssets(intro: URL? = nil, outro: URL? = nil, bgm: URL? = nil) throws {
        if let intro {
            let destName = "intro." + intro.pathExtension
            try Self.copy(source: intro, into: assetsDirectoryURL, as: destName)
            show.assets.intro = "assets/\(destName)"
        }
        if let outro {
            let destName = "outro." + outro.pathExtension
            try Self.copy(source: outro, into: assetsDirectoryURL, as: destName)
            show.assets.outro = "assets/\(destName)"
        }
        if let bgm {
            let destName = "bgm." + bgm.pathExtension
            try Self.copy(source: bgm, into: assetsDirectoryURL, as: destName)
            show.assets.bgm = "assets/\(destName)"
        }
        try save()
    }

    // MARK: - Discovery

    /// Hard cap on how deep `discover(recursive:)` walks, so a pathological
    /// directory tree can't hang the scan. The library only nests a couple of
    /// levels (`Maycast/Shows/<show>`), so this is generous.
    private static let maxDiscoveryDepth = 6

    /// Scan `directory` for Shows and return the openable ones, sorted
    /// case-insensitively by display name. A missing directory yields an empty
    /// list rather than an error. Used by the GUI to offer one-click Show
    /// attach without a file panel, and exposed via `maycast show list`.
    ///
    /// - Parameter recursive: when `false` (default) only the directory's
    ///   immediate children are considered, and a Show must carry the
    ///   `.maycastshow` extension — the original contract. When `true` the whole
    ///   subtree is walked and *any* folder holding a valid `show.json` counts
    ///   as a Show (extension-agnostic), so Shows that already sit in the
    ///   library — however they were placed there — are picked up. The walk
    ///   never descends into a recognized Show or an Episode (`.maycast`)
    ///   bundle, and is bounded by `maxDiscoveryDepth`.
    public static func discover(in directory: URL, recursive: Bool = false) -> [DiscoveredShow] {
        let fm = FileManager.default
        var shows: [DiscoveredShow] = []
        var seen = Set<String>()

        func scan(_ dir: URL, depth: Int) {
            guard let entries = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return }

            for entry in entries {
                let ext = entry.pathExtension.lowercased()
                // Episode bundles are never Shows — and we must not wander into
                // their internals looking for one.
                if ext == MaycastCoreInfo.episodeBundleExtension { continue }

                // In the (default) non-recursive mode a Show must still carry
                // the `.maycastshow` extension, preserving the old contract.
                let extensionOK = recursive || ext == MaycastCoreInfo.showBundleExtension
                if extensionOK, let bundle = try? ShowBundle.open(at: entry) {
                    if seen.insert(entry.standardizedFileURL.path).inserted {
                        shows.append(DiscoveredShow(name: bundle.show.name, url: entry))
                    }
                    // A Show is a leaf: don't descend into its `episodes/`.
                    continue
                }

                if recursive, depth + 1 < maxDiscoveryDepth {
                    let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    if isDir { scan(entry, depth: depth + 1) }
                }
            }
        }

        scan(directory, depth: 0)
        return shows.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private static func copy(source: URL, into directory: URL, as filename: String) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else {
            throw MaycastError.sourceFileNotFound(source)
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(filename)
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        do {
            try fm.copyItem(at: source, to: destination)
        } catch {
            throw MaycastError.ioError(destination, underlying: error)
        }
    }
}

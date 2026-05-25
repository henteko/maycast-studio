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

    /// Scan `directory` (non-recursively) for `.maycastshow` bundles and return
    /// the openable ones, sorted case-insensitively by display name. Entries
    /// whose `show.json` is missing or unreadable are skipped; a missing
    /// directory yields an empty list rather than an error. Used by the GUI to
    /// offer one-click Show attach without a file panel, and exposed via
    /// `maycast show list`.
    public static func discover(in directory: URL) -> [DiscoveredShow] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var shows: [DiscoveredShow] = []
        for entry in entries
        where entry.pathExtension.lowercased() == MaycastCoreInfo.showBundleExtension {
            guard let bundle = try? ShowBundle.open(at: entry) else { continue }
            shows.append(DiscoveredShow(name: bundle.show.name, url: entry))
        }
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

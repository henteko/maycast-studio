import Foundation

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
        url.appendingPathComponent(MaycastCore.showManifestFileName)
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
        let manifest = url.appendingPathComponent(MaycastCore.showManifestFileName)
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

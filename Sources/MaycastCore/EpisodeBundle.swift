import Foundation

/// Represents a `<name>.maycast` bundle on disk.
public struct EpisodeBundle: Sendable {
    public let url: URL
    public var episode: Episode

    public init(url: URL, episode: Episode) {
        self.url = url
        self.episode = episode
    }

    // MARK: - Paths

    public var manifestURL: URL {
        url.appendingPathComponent(MaycastCore.episodeManifestFileName)
    }

    public var sourcesDirectoryURL: URL {
        url.appendingPathComponent("sources", isDirectory: true)
    }

    public var intermediateDirectoryURL: URL {
        url.appendingPathComponent("intermediate", isDirectory: true)
    }

    public func intermediateDirectoryURL(for trackID: String) -> URL {
        intermediateDirectoryURL.appendingPathComponent(trackID, isDirectory: true)
    }

    public var assetsDirectoryURL: URL {
        url.appendingPathComponent("assets", isDirectory: true)
    }

    public var exportsDirectoryURL: URL {
        url.appendingPathComponent("exports", isDirectory: true)
    }

    // MARK: - Create / Open / Save

    /// Create a new Episode bundle. If `show` is provided, the show's assets are
    /// snapshot-copied into the new Episode and `episode.show` is set to a relative path.
    public static func create(at url: URL, show: ShowBundle? = nil) throws -> EpisodeBundle {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            throw MaycastError.bundleAlreadyExists(url)
        }
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            try fm.createDirectory(at: url.appendingPathComponent("sources", isDirectory: true),
                                   withIntermediateDirectories: true)
            try fm.createDirectory(at: url.appendingPathComponent("intermediate", isDirectory: true),
                                   withIntermediateDirectories: true)
            try fm.createDirectory(at: url.appendingPathComponent("assets", isDirectory: true),
                                   withIntermediateDirectories: true)
            try fm.createDirectory(at: url.appendingPathComponent("exports", isDirectory: true),
                                   withIntermediateDirectories: true)
        } catch {
            throw MaycastError.ioError(url, underlying: error)
        }

        let id = url.deletingPathExtension().lastPathComponent
        var episode = Episode(id: id)

        if let show {
            episode.show = Self.relativePath(from: url, to: show.url)
            try Self.copyShowAssetsSnapshot(from: show, into: url.appendingPathComponent("assets", isDirectory: true),
                                            mix: &episode.mix)
        }

        let bundle = EpisodeBundle(url: url, episode: episode)
        try bundle.save()
        return bundle
    }

    public static func open(at url: URL) throws -> EpisodeBundle {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            throw MaycastError.bundleNotFound(url)
        }
        let manifest = url.appendingPathComponent(MaycastCore.episodeManifestFileName)
        guard fm.fileExists(atPath: manifest.path) else {
            throw MaycastError.manifestNotFound(manifest)
        }
        let episode = try JSONCoders.decode(Episode.self, from: manifest)
        return EpisodeBundle(url: url, episode: episode)
    }

    public func save() throws {
        try JSONCoders.encode(episode, to: manifestURL)
    }

    // MARK: - Track / Generation helpers

    public func track(withID id: String) -> Track? {
        episode.tracks.first(where: { $0.id == id })
    }

    public mutating func upsertTrack(_ track: Track) {
        if let index = episode.tracks.firstIndex(where: { $0.id == track.id }) {
            episode.tracks[index] = track
        } else {
            episode.tracks.append(track)
        }
    }

    /// Append a new generation file path (relative to bundle root) to the track's history
    /// and set it as the current.
    public mutating func appendGeneration(trackID: String, relativePath: String) throws {
        guard let index = episode.tracks.firstIndex(where: { $0.id == trackID }) else {
            throw MaycastError.trackNotFound(id: trackID)
        }
        episode.tracks[index].history.append(relativePath)
        episode.tracks[index].current = relativePath
    }

    /// Compute the next generation number for a track (history.count + 1, zero-padded).
    public func nextGenerationNumber(for trackID: String) -> Int {
        guard let track = track(withID: trackID) else { return 1 }
        return track.history.count + 1
    }

    public static func formatGenerationNumber(_ n: Int) -> String {
        String(format: "%03d", n)
    }

    /// Set the track's `current` pointer to the Nth entry of its history (1-indexed).
    /// `history` itself is left unchanged so that subsequent operations are still
    /// numbered sequentially without colliding with on-disk files from the future.
    public mutating func revert(trackID: String, to generation: Int) throws {
        guard let index = episode.tracks.firstIndex(where: { $0.id == trackID }) else {
            throw MaycastError.trackNotFound(id: trackID)
        }
        let history = episode.tracks[index].history
        guard generation >= 1, generation <= history.count else {
            throw MaycastError.generationOutOfRange(track: trackID, generation: generation, max: history.count)
        }
        episode.tracks[index].current = history[generation - 1]
        try save()
    }

    /// Compute the URL of the params sidecar that pairs with the given generation file.
    public func paramsSidecarURL(forGenerationRelativePath relativePath: String) -> URL {
        let fileURL = url.appendingPathComponent(relativePath)
        let stem = fileURL.deletingPathExtension().lastPathComponent
        return fileURL.deletingLastPathComponent().appendingPathComponent("\(stem).params.json")
    }

    // MARK: - Import

    /// Import a source audio file as a new track. Copies the original into
    /// `sources/` preserving its extension (for the user's reference), then
    /// decodes it and writes a normalized WAV at `intermediate/<track>/001_import.wav`
    /// along with `params.json` / `transcript.json` sidecars. The bundle is saved.
    public mutating func importTrack(from sourceURL: URL, as trackID: String) throws -> Track {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sourceURL.path) else {
            throw MaycastError.sourceFileNotFound(sourceURL)
        }

        let ext = sourceURL.pathExtension.isEmpty ? "wav" : sourceURL.pathExtension
        let sourceRelPath = "sources/\(trackID).\(ext)"
        let sourceDest = url.appendingPathComponent(sourceRelPath)

        try fm.createDirectory(at: sourcesDirectoryURL, withIntermediateDirectories: true)
        if fm.fileExists(atPath: sourceDest.path) {
            try fm.removeItem(at: sourceDest)
        }
        do {
            try fm.copyItem(at: sourceURL, to: sourceDest)
        } catch {
            throw MaycastError.ioError(sourceDest, underlying: error)
        }

        let trackDir = intermediateDirectoryURL(for: trackID)
        try fm.createDirectory(at: trackDir, withIntermediateDirectories: true)

        // Decode source → normalize to WAV in intermediate/<track>/001_import.wav
        let genNumber = "001"
        let genFilename = "\(genNumber)_import.wav"
        let genRelPath = "intermediate/\(trackID)/\(genFilename)"
        let genDest = url.appendingPathComponent(genRelPath)
        let buffer = try AudioIO.read(from: sourceDest)
        try AudioIO.writeWAV(buffer, to: genDest)

        // Sidecars
        let paramsURL = trackDir.appendingPathComponent("\(genNumber)_import.params.json")
        let transcriptURL = trackDir.appendingPathComponent("\(genNumber)_import.transcript.json")
        let arrangementURL = trackDir.appendingPathComponent("\(genNumber)_import.arrangement.json")
        let paramsRecord = OperationParamsRecord(op: "import", input: sourceRelPath)
        try JSONCoders.encode(paramsRecord, to: paramsURL)
        try JSONCoders.encode(Transcript(), to: transcriptURL)
        let initialArrangement = Arrangement.single(sourceDuration: buffer.duration)
        try JSONCoders.encode(initialArrangement, to: arrangementURL)

        let track = Track(
            id: trackID,
            source: sourceRelPath,
            current: genRelPath,
            history: [genRelPath]
        )
        upsertTrack(track)
        try save()
        return track
    }

    // MARK: - Append generation (used by Slice / Polish stubs and real impls)

    /// Append a new generation derived from the track's current audio.
    ///
    /// By default the new generation is a copy of the current buffer (used by
    /// stub services). Real operations pass a `transform` closure that maps
    /// the input `AudioBuffer` to the output one.
    ///
    /// Always writes the new generation as WAV.
    public mutating func appendOperationGeneration(
        trackID: String,
        operation: String,
        params: JSONValue?,
        transform: ((AudioBuffer) throws -> AudioBuffer)? = nil
    ) throws -> Track {
        guard let track = self.track(withID: trackID) else {
            throw MaycastError.trackNotFound(id: trackID)
        }
        let currentURL = url.appendingPathComponent(track.current)
        let n = nextGenerationNumber(for: trackID)
        let nStr = Self.formatGenerationNumber(n)
        let newFilename = "\(nStr)_\(operation).wav"
        let newRel = "intermediate/\(trackID)/\(newFilename)"
        let newDest = url.appendingPathComponent(newRel)

        let fm = FileManager.default
        let trackDir = intermediateDirectoryURL(for: trackID)
        try fm.createDirectory(at: trackDir, withIntermediateDirectories: true)

        let inputBuffer = try AudioIO.read(from: currentURL)
        let outputBuffer = try (transform?(inputBuffer)) ?? inputBuffer
        try AudioIO.writeWAV(outputBuffer, to: newDest)

        let paramsURL = trackDir.appendingPathComponent("\(nStr)_\(operation).params.json")
        let transcriptURL = trackDir.appendingPathComponent("\(nStr)_\(operation).transcript.json")
        try JSONCoders.encode(
            OperationParamsRecord(op: operation, input: track.current, params: params),
            to: paramsURL
        )

        // Always write an empty transcript: the audio has changed (or, for
        // identity transforms like a transcribe pass that has its own
        // post-write, will be overwritten momentarily). Carrying the prior
        // transcript forward would leave stale word timestamps on the new
        // generation, which is confusing for the user.
        try JSONCoders.encode(Transcript(), to: transcriptURL)

        // Carry the arrangement forward unchanged (Polish / Transcribe etc.).
        let arrangementURL = trackDir.appendingPathComponent("\(nStr)_\(operation).arrangement.json")
        if let currentArrangement = try currentArrangement(forTrackID: trackID) {
            try JSONCoders.encode(currentArrangement, to: arrangementURL)
        } else {
            try JSONCoders.encode(
                Arrangement.single(sourceDuration: outputBuffer.duration),
                to: arrangementURL
            )
        }

        try appendGeneration(trackID: trackID, relativePath: newRel)
        try save()
        return self.track(withID: trackID)!
    }

    /// Apply a new arrangement to a track and produce the next `slice` generation.
    ///
    /// The new audio is rendered from the previous generation using `AudioIO.render`
    /// with the supplied `newArrangement` (so deletes/moves are *baked* into the
    /// audio as silence). The on-disk arrangement is then **reset to a single clip
    /// covering the rendered file** — the edit "history" lives only in the audio
    /// itself, and the next slice session opens against a clean canvas where
    /// `current.wav` *is* the source.
    public mutating func applySliceArrangement(
        trackID: String,
        newArrangement: Arrangement,
        params: JSONValue? = nil
    ) throws -> Track {
        guard let track = self.track(withID: trackID) else {
            throw MaycastError.trackNotFound(id: trackID)
        }
        let currentURL = url.appendingPathComponent(track.current)
        let sourceBuffer = try AudioIO.read(from: currentURL)
        let rendered = AudioIO.render(arrangement: newArrangement, from: sourceBuffer)

        let n = nextGenerationNumber(for: trackID)
        let nStr = Self.formatGenerationNumber(n)
        let newFilename = "\(nStr)_slice.wav"
        let newRel = "intermediate/\(trackID)/\(newFilename)"
        let newDest = url.appendingPathComponent(newRel)

        let fm = FileManager.default
        let trackDir = intermediateDirectoryURL(for: trackID)
        try fm.createDirectory(at: trackDir, withIntermediateDirectories: true)
        try AudioIO.writeWAV(rendered, to: newDest)

        let paramsURL = trackDir.appendingPathComponent("\(nStr)_slice.params.json")
        let arrangementURL = trackDir.appendingPathComponent("\(nStr)_slice.arrangement.json")
        let transcriptURL = trackDir.appendingPathComponent("\(nStr)_slice.transcript.json")
        try JSONCoders.encode(
            OperationParamsRecord(op: "slice", input: track.current, params: params),
            to: paramsURL
        )
        // Reset arrangement to one full-length clip — the just-rendered audio
        // contains everything the user wants preserved, so the next slice
        // session should see it as a clean single block.
        let resetArrangement = Arrangement.single(sourceDuration: rendered.duration)
        try JSONCoders.encode(resetArrangement, to: arrangementURL)
        // Slice changes the audio (deletes/moves are baked in), so prior word
        // timestamps no longer match. Always start the new generation with an
        // empty transcript.
        try JSONCoders.encode(Transcript(), to: transcriptURL)

        try appendGeneration(trackID: trackID, relativePath: newRel)
        try save()
        return self.track(withID: trackID)!
    }

    /// Resolve the transcript sidecar URL for a track's current generation.
    public func currentTranscriptURL(forTrackID trackID: String) -> URL? {
        guard let track = self.track(withID: trackID) else { return nil }
        let currentURL = url.appendingPathComponent(track.current)
        let stem = currentURL.deletingPathExtension().lastPathComponent
        return currentURL.deletingLastPathComponent().appendingPathComponent("\(stem).transcript.json")
    }

    /// Resolve the arrangement sidecar URL for a track's current generation.
    public func currentArrangementURL(forTrackID trackID: String) -> URL? {
        guard let track = self.track(withID: trackID) else { return nil }
        let currentURL = url.appendingPathComponent(track.current)
        let stem = currentURL.deletingPathExtension().lastPathComponent
        return currentURL.deletingLastPathComponent().appendingPathComponent("\(stem).arrangement.json")
    }

    /// Compute the arrangement sidecar URL paired with a specific generation file.
    public func arrangementSidecarURL(forGenerationRelativePath relativePath: String) -> URL {
        let fileURL = url.appendingPathComponent(relativePath)
        let stem = fileURL.deletingPathExtension().lastPathComponent
        return fileURL.deletingLastPathComponent().appendingPathComponent("\(stem).arrangement.json")
    }

    /// Load the arrangement for a track's current generation (returns `nil` if not present).
    public func currentArrangement(forTrackID trackID: String) throws -> Arrangement? {
        guard let url = currentArrangementURL(forTrackID: trackID) else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONCoders.decode(Arrangement.self, from: url)
    }

    // MARK: - Show assets snapshot

    private static func copyShowAssetsSnapshot(
        from show: ShowBundle,
        into destination: URL,
        mix: inout MixConfig
    ) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        if let intro = show.show.assets.intro {
            let src = show.url.appendingPathComponent(intro)
            let dest = destination.appendingPathComponent(src.lastPathComponent)
            try Self.copyFile(from: src, to: dest)
            mix.intro = "assets/\(src.lastPathComponent)"
        }
        if let outro = show.show.assets.outro {
            let src = show.url.appendingPathComponent(outro)
            let dest = destination.appendingPathComponent(src.lastPathComponent)
            try Self.copyFile(from: src, to: dest)
            mix.outro = "assets/\(src.lastPathComponent)"
        }
        if let bgm = show.show.assets.bgm {
            let src = show.url.appendingPathComponent(bgm)
            let dest = destination.appendingPathComponent(src.lastPathComponent)
            try Self.copyFile(from: src, to: dest)
            mix.bgm = BGMConfig(file: "assets/\(src.lastPathComponent)")
        }
    }

    private static func copyFile(from src: URL, to dest: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        do {
            try fm.copyItem(at: src, to: dest)
        } catch {
            throw MaycastError.ioError(dest, underlying: error)
        }
    }

    // MARK: - Path helpers

    /// Compute a relative path from `base` to `target` (both must be on disk).
    static func relativePath(from base: URL, to target: URL) -> String {
        let baseComponents = base.standardizedFileURL.pathComponents
        let targetComponents = target.standardizedFileURL.pathComponents
        var commonPrefix = 0
        while commonPrefix < min(baseComponents.count, targetComponents.count),
              baseComponents[commonPrefix] == targetComponents[commonPrefix] {
            commonPrefix += 1
        }
        let upCount = baseComponents.count - commonPrefix
        let upPath = Array(repeating: "..", count: upCount)
        let downPath = Array(targetComponents[commonPrefix...])
        return (upPath + downPath).joined(separator: "/")
    }
}

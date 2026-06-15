import Foundation
import os

/// Represents a `<name>.maycast` bundle on disk.
public struct EpisodeBundle: Sendable {
    /// Used by `importTrack` to emit step-by-step traces (file copy → audio
    /// read → WAV write). Visible in Xcode's console and in Console.app under
    /// subsystem "MaycastCore" / category "Import".
    fileprivate static let importLog = Logger(subsystem: "MaycastCore", category: "Import")

    /// Diagnostic log for `applySliceArrangement`. Use `os.Logger` instead of
    /// `print()` because slice runs inside `MaycastSliceService`, which uses
    /// stdout for JSON-over-stdio IPC — anything on stdout would corrupt the
    /// response stream.
    fileprivate static let sliceLog = Logger(subsystem: "MaycastCore", category: "Slice")

    public let url: URL
    public var episode: Episode

    public init(url: URL, episode: Episode) {
        self.url = url
        self.episode = episode
    }

    // MARK: - Paths

    public var manifestURL: URL {
        url.appendingPathComponent(MaycastCoreInfo.episodeManifestFileName)
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
        let manifest = url.appendingPathComponent(MaycastCoreInfo.episodeManifestFileName)
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
    ///
    /// For a video track the video chain is kept in lockstep so the generation
    /// indices of `history` and `videoHistory` always line up (which is what
    /// undo / redo / revert rely on to move the video alongside the audio). Pass
    /// `videoRelativePath` when the operation produced a freshly cut video
    /// (slice); otherwise the current video is carried forward unchanged (the
    /// operation didn't touch the picture, e.g. an audio-only polish).
    public mutating func appendGeneration(
        trackID: String,
        relativePath: String,
        videoRelativePath: String? = nil
    ) throws {
        guard let index = episode.tracks.firstIndex(where: { $0.id == trackID }) else {
            throw MaycastError.trackNotFound(id: trackID)
        }
        episode.tracks[index].history.append(relativePath)
        episode.tracks[index].current = relativePath

        if episode.tracks[index].videoCurrent != nil {
            let video = videoRelativePath ?? episode.tracks[index].videoCurrent!
            episode.tracks[index].videoHistory = (episode.tracks[index].videoHistory ?? []) + [video]
            episode.tracks[index].videoCurrent = video
        }
    }

    /// Move a video track's `videoCurrent` to the entry of `videoHistory` that
    /// sits at the same generation index as the current audio generation. Used
    /// after undo / redo / revert change `current`, so the video follows.
    private mutating func syncVideoCurrentToAudio(trackIndex: Int) {
        guard episode.tracks[trackIndex].videoCurrent != nil,
              let videoHistory = episode.tracks[trackIndex].videoHistory,
              let idx = episode.tracks[trackIndex].history.firstIndex(of: episode.tracks[trackIndex].current),
              idx < videoHistory.count
        else { return }
        episode.tracks[trackIndex].videoCurrent = videoHistory[idx]
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
        syncVideoCurrentToAudio(trackIndex: index)
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
        let log = Self.importLog
        let started = Date()
        let fm = FileManager.default
        guard fm.fileExists(atPath: sourceURL.path) else {
            log.error("importTrack[\(trackID, privacy: .public)]: source not found at \(sourceURL.path, privacy: .public)")
            print("[Import:\(trackID)] source not found: \(sourceURL.path)")
            throw MaycastError.sourceFileNotFound(sourceURL)
        }
        log.info("importTrack[\(trackID, privacy: .public)]: starting (source=\(sourceURL.lastPathComponent, privacy: .public))")
        print("[Import:\(trackID)] starting (source=\(sourceURL.path))")

        let ext = sourceURL.pathExtension.isEmpty ? "wav" : sourceURL.pathExtension
        let sourceRelPath = "sources/\(trackID).\(ext)"
        let sourceDest = url.appendingPathComponent(sourceRelPath)

        try fm.createDirectory(at: sourcesDirectoryURL, withIntermediateDirectories: true)
        if fm.fileExists(atPath: sourceDest.path) {
            try fm.removeItem(at: sourceDest)
        }
        do {
            print("[Import:\(trackID)] copying to \(sourceDest.path)")
            try fm.copyItem(at: sourceURL, to: sourceDest)
            let copyDur = Date().timeIntervalSince(started)
            print(String(format: "[Import:%@] copy complete in %.2fs", trackID, copyDur))
        } catch {
            log.error("importTrack[\(trackID, privacy: .public)]: copy failed: \(String(describing: error), privacy: .public)")
            print("[Import:\(trackID)] copy FAILED: \(error)")
            throw MaycastError.ioError(sourceDest, underlying: error)
        }

        let trackDir = intermediateDirectoryURL(for: trackID)
        try fm.createDirectory(at: trackDir, withIntermediateDirectories: true)

        // Transcode source → 16-bit PCM WAV at intermediate/<track>/001_import.wav.
        // Uses afconvert under the hood so CoreAudio streams the conversion
        // chunk-by-chunk instead of round-tripping through a Swift array; see
        // `AudioIO.transcodeToWAV` for details.
        let genNumber = "001"
        let genFilename = "\(genNumber)_import.wav"
        let genRelPath = "intermediate/\(trackID)/\(genFilename)"
        let genDest = url.appendingPathComponent(genRelPath)
        let mediaKind = MediaKind.of(sourceDest)
        let transcodeStart = Date()
        switch mediaKind {
        case .video:
            // Pull the audio out of the video for editing; the video itself is
            // kept (as the immutable source) for the per-speaker mp4 export.
            print("[Import:\(trackID)] extracting audio from video via ffmpeg…")
            try AudioIO.extractAudioToWAV(fromVideo: sourceDest, to: genDest)
        case .audio:
            print("[Import:\(trackID)] transcoding to WAV via afconvert…")
            try AudioIO.transcodeToWAV(from: sourceDest, to: genDest)
        }
        print(String(format: "[Import:%@] decoded in %.2fs", trackID, Date().timeIntervalSince(transcodeStart)))

        // Probe the destination's duration via AVAudioFile metadata only — no
        // PCM frames are decoded, which keeps import I/O-bound rather than
        // CPU-bound.
        let durationProbeStart = Date()
        let sourceDuration = try AudioIO.probeDuration(of: genDest)
        print(String(
            format: "[Import:%@] duration probed: %.2fs (in %.3fs)",
            trackID, sourceDuration, Date().timeIntervalSince(durationProbeStart)
        ))

        // Sidecars
        let paramsURL = trackDir.appendingPathComponent("\(genNumber)_import.params.json")
        let transcriptURL = trackDir.appendingPathComponent("\(genNumber)_import.transcript.json")
        let arrangementURL = trackDir.appendingPathComponent("\(genNumber)_import.arrangement.json")
        let paramsRecord = OperationParamsRecord(op: "import", input: sourceRelPath)
        try JSONCoders.encode(paramsRecord, to: paramsURL)
        try JSONCoders.encode(Transcript(), to: transcriptURL)
        let initialArrangement = Arrangement.single(sourceDuration: sourceDuration)
        try JSONCoders.encode(initialArrangement, to: arrangementURL)

        // For a video import, the imported video is generation 001 of the
        // video chain (kept at its immutable `sources/` path — no copy into
        // `intermediate/`). Slice / polish will append cut video generations
        // later, keeping the video chain on the same timeline as the audio.
        let isVideo = mediaKind == .video
        let track = Track(
            id: trackID,
            source: sourceRelPath,
            current: genRelPath,
            history: [genRelPath],
            videoSource: isVideo ? sourceRelPath : nil,
            videoCurrent: isVideo ? sourceRelPath : nil,
            videoHistory: isVideo ? [sourceRelPath] : nil
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
        batchID: String? = nil,
        transform: ((AudioBuffer) throws -> AudioBuffer)? = nil
    ) throws -> Track {
        guard let track = self.track(withID: trackID) else {
            throw MaycastError.trackNotFound(id: trackID)
        }
        let previousCurrent = track.current
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

        // Always reset the arrangement to a single full-length clip matching
        // the actually-rendered audio. Carrying the previous arrangement
        // forward used to leave stale `sourceEnd` values when the operation
        // changed audio length (e.g. Auphonic's filler/silence cutters), so
        // the next slice session would build clips that overshoot the real
        // audio and bake trailing silence into the next generation.
        let arrangementURL = trackDir.appendingPathComponent("\(nStr)_\(operation).arrangement.json")
        try JSONCoders.encode(
            Arrangement.single(sourceDuration: outputBuffer.duration),
            to: arrangementURL
        )

        try appendGeneration(trackID: trackID, relativePath: newRel)
        recordOperation(
            batchID: batchID ?? UUID().uuidString,
            kind: operation,
            trackID: trackID,
            from: previousCurrent,
            to: newRel
        )
        try save()
        return self.track(withID: trackID)!
    }

    /// Append a `polish` generation that ingests externally-processed media
    /// (e.g. Auphonic output) for both the audio and — when the track has video
    /// — the video chain, keeping them on the same timeline.
    ///
    /// `audioWAVSource` is a WAV holding the cleaned audio (the GUI extracts it
    /// from the processed file). `videoSource`, when given, is the processed
    /// video to adopt as the new video generation; for audio-only tracks it's
    /// `nil` and the (absent) video chain is left untouched. Auphonic's
    /// filler / silence cutters change both the audio length **and** the video
    /// in lockstep, so the two stay synced without us re-cutting anything.
    @discardableResult
    public mutating func appendPolishGeneration(
        trackID: String,
        audioWAVSource: URL,
        videoSource: URL? = nil,
        params: JSONValue? = nil,
        batchID: String? = nil
    ) throws -> Track {
        guard let track = self.track(withID: trackID) else {
            throw MaycastError.trackNotFound(id: trackID)
        }
        let previousCurrent = track.current
        let n = nextGenerationNumber(for: trackID)
        let nStr = Self.formatGenerationNumber(n)

        let fm = FileManager.default
        let trackDir = intermediateDirectoryURL(for: trackID)
        try fm.createDirectory(at: trackDir, withIntermediateDirectories: true)

        // Audio: re-write through AudioIO so the stored generation is a
        // normalized WAV regardless of what the caller handed us.
        let audioRel = "intermediate/\(trackID)/\(nStr)_polish.wav"
        let audioBuffer = try AudioIO.read(from: audioWAVSource)
        try AudioIO.writeWAV(audioBuffer, to: url.appendingPathComponent(audioRel))

        // Video: adopt the processed video as the new video generation,
        // preserving its container extension.
        var videoRel: String? = nil
        if track.hasVideo, let videoSource {
            let ext = videoSource.pathExtension.isEmpty ? "mp4" : videoSource.pathExtension
            let rel = "intermediate/\(trackID)/\(nStr)_polish.\(ext)"
            let dest = url.appendingPathComponent(rel)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: videoSource, to: dest)
            videoRel = rel
        }

        // Sidecars: params, empty transcript, reset arrangement to a single
        // clip over the new audio (same contract as every other operation).
        try JSONCoders.encode(
            OperationParamsRecord(op: "polish", input: previousCurrent, params: params),
            to: trackDir.appendingPathComponent("\(nStr)_polish.params.json")
        )
        try JSONCoders.encode(Transcript(), to: trackDir.appendingPathComponent("\(nStr)_polish.transcript.json"))
        try JSONCoders.encode(
            Arrangement.single(sourceDuration: audioBuffer.duration),
            to: trackDir.appendingPathComponent("\(nStr)_polish.arrangement.json")
        )

        try appendGeneration(trackID: trackID, relativePath: audioRel, videoRelativePath: videoRel)
        recordOperation(
            batchID: batchID ?? UUID().uuidString,
            kind: "polish",
            trackID: trackID,
            from: previousCurrent,
            to: audioRel
        )
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
        params: JSONValue? = nil,
        batchID: String? = nil
    ) throws -> Track {
        guard let track = self.track(withID: trackID) else {
            throw MaycastError.trackNotFound(id: trackID)
        }
        let previousCurrent = track.current
        let currentURL = url.appendingPathComponent(track.current)
        let sourceBuffer = try AudioIO.read(from: currentURL)
        // Diagnostic: dump the arrangement being rendered so we can verify
        // that timelineEnd doesn't accidentally exceed the audible content
        // (= trailing silence bug). Use os.Logger + stderr instead of
        // `print()` so the XPC services that talk JSON over stdout don't get
        // their response stream corrupted.
        Self.sliceLog.info("[Slice:\(trackID, privacy: .public)] applying arrangement — source duration=\(sourceBuffer.duration, format: .fixed(precision: 3))s, clips=\(newArrangement.clips.count, privacy: .public)")
        for (i, clip) in newArrangement.clips.enumerated() {
            Self.sliceLog.info("[Slice:\(trackID, privacy: .public)]   clip[\(i, privacy: .public)] src=\(clip.sourceStart, format: .fixed(precision: 3))..\(clip.sourceEnd, format: .fixed(precision: 3)) tl=\(clip.timelineStart, format: .fixed(precision: 3))..\(clip.timelineEnd, format: .fixed(precision: 3))")
        }
        Self.sliceLog.info("[Slice:\(trackID, privacy: .public)] arrangement.totalDuration=\(newArrangement.totalDuration, format: .fixed(precision: 3)) → rendering")
        let rendered = AudioIO.render(arrangement: newArrangement, from: sourceBuffer)
        Self.sliceLog.info("[Slice:\(trackID, privacy: .public)] rendered.duration=\(rendered.duration, format: .fixed(precision: 3)) frames=\(rendered.frameCount, privacy: .public)")

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

        // Video track: cut the picture with the same arrangement so it stays on
        // the new audio timeline. Produces a video-only generation alongside the
        // WAV; the export muxes the edited audio back in.
        var videoNewRel: String? = nil
        if track.hasVideo, let videoCurrentRel = track.videoCurrent {
            let videoRel = "intermediate/\(trackID)/\(nStr)_slice.mp4"
            let videoDest = url.appendingPathComponent(videoRel)
            Self.sliceLog.info("[Slice:\(trackID, privacy: .public)] cutting video to match arrangement → \(videoRel, privacy: .public)")
            try VideoEdit.renderArrangement(
                arrangement: newArrangement,
                from: url.appendingPathComponent(videoCurrentRel),
                to: videoDest
            )
            videoNewRel = videoRel
        }

        try appendGeneration(trackID: trackID, relativePath: newRel, videoRelativePath: videoNewRel)
        recordOperation(
            batchID: batchID ?? UUID().uuidString,
            kind: "slice",
            trackID: trackID,
            from: previousCurrent,
            to: newRel
        )
        try save()
        return self.track(withID: trackID)!
    }

    // MARK: - Undo / Redo

    /// Append an entry to the episode-level operation log and clear the redo
    /// stack. Saves are handled by the caller.
    private mutating func recordOperation(
        batchID: String,
        kind: String,
        trackID: String,
        from: String,
        to: String
    ) {
        episode.operations.append(OperationLogEntry(
            batchID: batchID, kind: kind, trackID: trackID, from: from, to: to
        ))
        // A fresh op invalidates the redo stack — once you branch, the
        // alternate timeline is gone.
        episode.undone.removeAll()
    }

    /// Revert the most recent batch of operations. All entries that share the
    /// last `batchID` in the operation log are reverted together (so a
    /// multi-track Polish that updated both speakers reverts as one unit).
    /// Returns the entries that were reverted, or nil if there is nothing to
    /// undo.
    @discardableResult
    public mutating func undo() throws -> [OperationLogEntry]? {
        guard let lastBatch = episode.operations.last?.batchID else { return nil }
        var reverted: [OperationLogEntry] = []
        while let last = episode.operations.last, last.batchID == lastBatch {
            episode.operations.removeLast()
            reverted.insert(last, at: 0)
            guard let index = episode.tracks.firstIndex(where: { $0.id == last.trackID }) else {
                continue
            }
            episode.tracks[index].current = last.from
            syncVideoCurrentToAudio(trackIndex: index)
        }
        episode.undone.append(contentsOf: reverted)
        try save()
        return reverted
    }

    /// Re-apply the most recent batch of undone operations.
    @discardableResult
    public mutating func redo() throws -> [OperationLogEntry]? {
        guard let lastBatch = episode.undone.last?.batchID else { return nil }
        var replayed: [OperationLogEntry] = []
        while let last = episode.undone.last, last.batchID == lastBatch {
            episode.undone.removeLast()
            replayed.insert(last, at: 0)
            guard let index = episode.tracks.firstIndex(where: { $0.id == last.trackID }) else {
                continue
            }
            episode.tracks[index].current = last.to
            syncVideoCurrentToAudio(trackIndex: index)
        }
        episode.operations.append(contentsOf: replayed)
        try save()
        return replayed
    }

    /// Whether `undo()` would currently revert anything.
    public var canUndo: Bool { !episode.operations.isEmpty }

    /// Whether `redo()` would currently replay anything.
    public var canRedo: Bool { !episode.undone.isEmpty }

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

    // MARK: - Chapters

    /// Chapters sorted by start time (the canonical display / export order).
    public var sortedChapters: [Chapter] {
        episode.chapters.sorted { $0.start < $1.start }
    }

    /// Add a chapter and keep the list sorted by start. Returns the new chapter.
    /// Caller is responsible for `save()`.
    @discardableResult
    public mutating func addChapter(start: Double, title: String, source: ChapterSource = .manual) -> Chapter {
        let chapter = Chapter(start: max(0, start), title: title, source: source)
        episode.chapters.append(chapter)
        episode.chapters.sort { $0.start < $1.start }
        return chapter
    }

    /// Edit an existing chapter's start and/or title. A hand-edit of an
    /// AI-generated chapter promotes its source to `.edited`. Caller saves.
    public mutating func editChapter(id: String, start: Double? = nil, title: String? = nil) throws {
        guard let index = episode.chapters.firstIndex(where: { $0.id == id }) else {
            throw MaycastError.chapterNotFound(id: id)
        }
        if let start { episode.chapters[index].start = max(0, start) }
        if let title { episode.chapters[index].title = title }
        if episode.chapters[index].source == .generated {
            episode.chapters[index].source = .edited
        }
        episode.chapters.sort { $0.start < $1.start }
    }

    /// Remove a chapter by id. Caller saves.
    public mutating func removeChapter(id: String) throws {
        guard episode.chapters.contains(where: { $0.id == id }) else {
            throw MaycastError.chapterNotFound(id: id)
        }
        episode.chapters.removeAll { $0.id == id }
    }

    /// Replace the entire chapter list (used by `apply` and generation). The
    /// list is stored sorted by start. Caller saves.
    public mutating func setChapters(_ chapters: [Chapter]) {
        episode.chapters = chapters.sorted { $0.start < $1.start }
    }

    // MARK: - Edit cues

    /// Edit cues sorted by start time (the canonical display order).
    public var sortedEditCues: [EditCue] {
        episode.editCues.sorted { $0.start < $1.start }
    }

    /// Replace the entire edit-cue list (used by detection). Stored sorted by
    /// start. Caller is responsible for `save()`.
    public mutating func setEditCues(_ cues: [EditCue]) {
        episode.editCues = cues.sorted { $0.start < $1.start }
    }

    /// Merge the current-generation transcripts of every track into a single
    /// chronological segment list (voice timeline). Used as the input to
    /// chapter generation. Tracks without a transcript sidecar are skipped.
    public func mergedTranscriptSegments() -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        for track in episode.tracks {
            guard let transcriptURL = currentTranscriptURL(forTrackID: track.id),
                  FileManager.default.fileExists(atPath: transcriptURL.path),
                  let transcript = try? JSONCoders.decode(Transcript.self, from: transcriptURL)
            else { continue }
            segments.append(contentsOf: transcript.segments)
        }
        return segments.sorted { $0.start < $1.start }
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

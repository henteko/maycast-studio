import Foundation

/// Produces the episode's final deliverables:
///
/// - **mp3** — the full mix of every track (intro / outro / ducking from the
///   episode's `MixConfig`), with chapters embedded as ID3v2 frames. One file:
///   `exports/<episodeID>.mp3`.
/// - **mp4** — one per speaker that has video: that speaker's video muxed with
///   *their own* current audio, with the same chapters, and **no** intro /
///   outro. Files: `exports/<trackID>.mp4`.
///
/// All heavy lifting (mix compose) reuses the same `AudioIO` primitives as the
/// mix pipeline; the video mux / chapter embedding goes through `ffmpeg`, the
/// dependency already required for MP3 export.
///
/// Phase 1 note: the video chain is not yet cut by slice / polish, so a track's
/// `videoCurrent` is still the imported video. If the audio was edited, the mp4
/// picture and audio can drift — slice → video cut lands in Phase 2.
public struct EpisodeExporter: Sendable {
    public init() {}

    public struct Artifact: Sendable, Equatable {
        public enum Kind: String, Sendable { case mp3, mp4 }
        /// `nil` for the mp3 mix; the speaker's track id for a per-speaker mp4.
        public var trackID: String?
        public var relativePath: String
        public var kind: Kind

        public init(trackID: String?, relativePath: String, kind: Kind) {
            self.trackID = trackID
            self.relativePath = relativePath
            self.kind = kind
        }
    }

    /// Render the mp3 mix and every per-speaker mp4. `outputDir` is relative to
    /// the bundle (default `exports`). Returns the artifacts produced, in
    /// order: the mp3 first, then one mp4 per video track (by track order).
    public func exportAll(bundleURL: URL, outputDir: String = "exports") throws -> [Artifact] {
        let bundle = try EpisodeBundle.open(at: bundleURL)
        guard !bundle.episode.tracks.isEmpty else {
            throw MaycastError.invalidOperation("Episode has no tracks to export.")
        }

        var artifacts: [Artifact] = []
        artifacts.append(try exportMP3(bundle: bundle, bundleURL: bundleURL, outputDir: outputDir))
        for track in bundle.episode.tracks where track.hasVideo {
            artifacts.append(try exportSpeakerVideo(track: track, bundle: bundle, bundleURL: bundleURL, outputDir: outputDir))
        }
        return artifacts
    }

    // MARK: - mp3 (full mix)

    private func exportMP3(bundle: EpisodeBundle, bundleURL: URL, outputDir: String) throws -> Artifact {
        var buffers: [AudioBuffer] = []
        for track in bundle.episode.tracks {
            buffers.append(try AudioIO.read(from: bundleURL.appendingPathComponent(track.current)))
        }
        let voiceMaster = try AudioIO.mixParallel(buffers)

        let mix = bundle.episode.mix
        let introBuffer: AudioBuffer? = try mix.intro
            .map(bundleURL.appendingPathComponent)
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            .map { try AudioIO.read(from: $0) }
        let outroBuffer: AudioBuffer? = try mix.outro
            .map(bundleURL.appendingPathComponent)
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            .map { try AudioIO.read(from: $0) }

        let finalMix: AudioBuffer
        if introBuffer == nil && outroBuffer == nil {
            finalMix = voiceMaster
        } else {
            finalMix = try AudioIO.composeFinalMix(
                voiceMaster: voiceMaster,
                intro: introBuffer,
                outro: outroBuffer,
                introOffsetSec: mix.introOffsetSec,
                outroOffsetSec: mix.outroOffsetSec,
                duckingGainDB: mix.duckingGainDB,
                duckingFadeSec: mix.duckingFadeSec
            )
        }

        // Shift voice-timeline chapters by the intro lead onto the final mix.
        let introDur = introBuffer?.duration ?? 0
        let introOffset = max(0, min(mix.introOffsetSec, introDur))
        let voiceStartInFinal = max(0, introDur - introOffset)
        let total = finalMix.duration
        let chapters: [ExportChapter] = bundle.sortedChapters.compactMap { ch in
            let shifted = ch.start + voiceStartInFinal
            guard shifted <= total else { return nil }
            return ExportChapter(startSec: shifted, title: ch.title)
        }

        let rel = "\(outputDir)/\(bundle.episode.id).mp3"
        let outURL = bundleURL.appendingPathComponent(rel)
        try AssetExportPipeline(audio: finalMix, chapters: chapters, format: .mp3).write(to: outURL)
        return Artifact(trackID: nil, relativePath: rel, kind: .mp3)
    }

    // MARK: - mp4 (per speaker)

    private func exportSpeakerVideo(track: Track, bundle: EpisodeBundle, bundleURL: URL, outputDir: String) throws -> Artifact {
        guard let videoRel = track.videoCurrent else {
            throw MaycastError.invalidOperation("Track '\(track.id)' has no video to export.")
        }
        let videoURL = bundleURL.appendingPathComponent(videoRel)
        let audioURL = bundleURL.appendingPathComponent(track.current)

        let fm = FileManager.default
        let rel = "\(outputDir)/\(track.id).mp4"
        let outURL = bundleURL.appendingPathComponent(rel)
        try fm.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: outURL.path) { try fm.removeItem(at: outURL) }

        let ffmpeg = try FFmpeg.locate()
        let scratch = fm.temporaryDirectory.appendingPathComponent("maycast-mp4-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        // The per-speaker mp4 carries that speaker's own audio (no intro /
        // outro), so chapters apply directly on the voice timeline — clamped to
        // the audio length.
        let audioDur = (try? AudioIO.probeDuration(of: audioURL)) ?? 0
        let chapters: [ExportChapter] = bundle.sortedChapters.compactMap { ch in
            guard audioDur <= 0 || ch.start <= audioDur else { return nil }
            return ExportChapter(startSec: ch.start, title: ch.title)
        }

        var args = ["-i", videoURL.path, "-i", audioURL.path]
        var chapterMap: [String] = []
        if !chapters.isEmpty {
            let metaURL = scratch.appendingPathComponent("chapters.ffmeta")
            try FFMetadata.chaptersDocument(chapters: chapters, totalDuration: audioDur)
                .write(to: metaURL, atomically: true, encoding: .utf8)
            args += ["-i", metaURL.path]
            chapterMap = ["-map_metadata", "2", "-map_chapters", "2"]
        }
        args += ["-map", "0:v:0", "-map", "1:a:0"]
        args += chapterMap
        args += [
            "-c:v", "copy",          // keep the imported picture (Phase 1: uncut)
            "-c:a", "aac", "-b:a", "192k",
            "-shortest",
            outURL.path,
        ]

        do {
            try FFmpeg.run(args, executable: ffmpeg)
        } catch let error as MaycastError {
            throw MaycastError.audioWriteFailed(outURL, underlying: error)
        }
        return Artifact(trackID: track.id, relativePath: rel, kind: .mp4)
    }
}

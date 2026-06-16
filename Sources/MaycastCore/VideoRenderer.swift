import Foundation

/// Renders the episode's per-speaker **video** deliverables: one mp4 per track
/// that has video — that speaker's video (cut to match their edited audio via
/// the cumulative `videoEdit`) muxed with their own audio and the chapters, and
/// **no** intro / outro. Files: `exports/<trackID>.mp4`.
///
/// Audio output is a separate concern (`maycast mix` → mp3). The actual video
/// cut is done by `VideoEdit` (smart cut) at this single point — editing never
/// re-encodes the picture.
public struct VideoRenderer: Sendable {
    public init() {}

    public struct Artifact: Sendable, Equatable {
        public var trackID: String
        public var relativePath: String
        public init(trackID: String, relativePath: String) {
            self.trackID = trackID
            self.relativePath = relativePath
        }
    }

    /// `onProgress` reports `(label, fraction)` for the current speaker's render.
    public func renderAll(
        bundleURL: URL,
        outputDir: String = "exports",
        onProgress: (@Sendable (_ label: String, _ fraction: Double) -> Void)? = nil
    ) throws -> [Artifact] {
        let bundle = try EpisodeBundle.open(at: bundleURL)
        let videoTracks = bundle.episode.tracks.filter { $0.hasVideo }
        guard !videoTracks.isEmpty else {
            throw MaycastError.invalidOperation("Episode has no video tracks to render.")
        }
        var artifacts: [Artifact] = []
        for track in videoTracks {
            artifacts.append(try renderSpeaker(track: track, bundle: bundle, bundleURL: bundleURL, outputDir: outputDir, onProgress: onProgress))
        }
        return artifacts
    }

    private func renderSpeaker(
        track: Track,
        bundle: EpisodeBundle,
        bundleURL: URL,
        outputDir: String,
        onProgress: (@Sendable (String, Double) -> Void)?
    ) throws -> Artifact {
        guard let videoRel = track.videoSource, let videoEdit = track.videoEdit else {
            throw MaycastError.invalidOperation("Track '\(track.id)' has no video to render.")
        }
        let originalVideoURL = bundleURL.appendingPathComponent(videoRel)
        let audioURL = bundleURL.appendingPathComponent(track.current)

        let fm = FileManager.default
        let rel = "\(outputDir)/\(track.id).mp4"
        let outURL = bundleURL.appendingPathComponent(rel)
        try fm.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: outURL.path) { try fm.removeItem(at: outURL) }

        let scratch = fm.temporaryDirectory.appendingPathComponent("maycast-mp4-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        // 1) Apply the cumulative edit to the original video (smart cut).
        let label = "Rendering \(track.id).mp4"
        var stepProgress: (@Sendable (Double) -> Void)? = nil
        if let report = onProgress {
            stepProgress = { (f: Double) in report(label, f) }
        }
        let cutVideo = scratch.appendingPathComponent("cut.mp4")
        try VideoEdit.renderArrangement(arrangement: videoEdit, from: originalVideoURL, to: cutVideo, onProgress: stepProgress)

        // 2) Mux the cut picture with the speaker's own audio + chapters.
        let audioDur = (try? AudioIO.probeDuration(of: audioURL)) ?? 0
        let chapters: [ExportChapter] = bundle.sortedChapters.compactMap { ch in
            guard audioDur <= 0 || ch.start <= audioDur else { return nil }
            return ExportChapter(startSec: ch.start, title: ch.title)
        }

        var args = ["-i", cutVideo.path, "-i", audioURL.path]
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
        args += ["-c:v", "copy", "-c:a", "aac", "-b:a", "192k", "-shortest", outURL.path]
        do {
            try FFmpeg.run(args)
        } catch let error as MaycastError {
            throw MaycastError.audioWriteFailed(outURL, underlying: error)
        }
        return Artifact(trackID: track.id, relativePath: rel)
    }
}

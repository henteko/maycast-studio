import Foundation

/// A chapter marker positioned on the **final mix timeline** (seconds), ready
/// to be embedded. The caller (mix) is responsible for shifting voice-timeline
/// chapters by the intro lead before handing them here. See docs/chapters.md §6.
public struct ExportChapter: Sendable, Equatable {
    public var startSec: Double
    public var title: String

    public init(startSec: Double, title: String) {
        self.startSec = startSec
        self.title = title
    }
}

/// Output container for the final export.
public enum ExportFormat: Sendable {
    case mp3   // MPEG-1 Layer III (libmp3lame) + ID3v2 chapter frames
}

/// Writes an `AudioBuffer` to the final deliverable.
///
/// The mix is encoded to **MP3** (128 kbps stereo, libmp3lame) with chapters
/// embedded as **ID3v2 CHAP/CTOC** frames. MP3 chapters are read by the broad
/// set of podcast clients (notably Android players) that don't honour m4a/MPEG-4
/// chapter tracks — see docs/chapters.md §7.
///
/// macOS has no native MP3 encoder (`afconvert` / `AVAssetWriter` only decode
/// MP3), so the encode is delegated to a system `ffmpeg`. The pipeline writes
/// the PCM mix to a temporary WAV, generates an ffmetadata file describing the
/// chapters, then invokes ffmpeg to produce the final MP3.
public struct AssetExportPipeline {
    public var audio: AudioBuffer
    public var chapters: [ExportChapter]
    public var artwork: URL?
    public var format: ExportFormat

    public init(
        audio: AudioBuffer,
        chapters: [ExportChapter] = [],
        artwork: URL? = nil,
        format: ExportFormat = .mp3
    ) {
        self.audio = audio
        self.chapters = chapters
        self.artwork = artwork
        self.format = format
    }

    public func write(to url: URL, onProgress: (@Sendable (Double) -> Void)? = nil) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }

        // Locate ffmpeg up front so a missing dependency fails before we do any
        // (throwaway) work, with an actionable install hint.
        let ffmpeg = try FFmpeg.locate()

        // Scratch dir for the intermediate WAV + ffmetadata. Removed on the way
        // out regardless of success.
        let scratch = fm.temporaryDirectory.appendingPathComponent("maycast-export-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        let wavURL = scratch.appendingPathComponent("mix.wav")
        try AudioIO.writeWAV(audio, to: wavURL)

        let sorted = chapters.sorted { $0.startSec < $1.startSec }
        var args = ["-i", wavURL.path]

        if !sorted.isEmpty {
            let metaURL = scratch.appendingPathComponent("chapters.ffmeta")
            try FFMetadata.chaptersDocument(chapters: sorted, totalDuration: audio.duration)
                .write(to: metaURL, atomically: true, encoding: .utf8)
            args += ["-i", metaURL.path, "-map_metadata", "1", "-map_chapters", "1"]
        }

        args += [
            "-map", "0:a",
            "-codec:a", "libmp3lame",
            "-b:a", "128k",
            "-id3v2_version", "3",
            url.path,
        ]

        do {
            try FFmpeg.runWithProgress(args, executable: ffmpeg, expectedDurationSec: audio.duration, onProgress: onProgress)
        } catch let error as MaycastError {
            // Surface as an audio-write failure so callers' existing error
            // handling (XPC `.failure`, GUI alert) reports it uniformly, while
            // keeping ffmpeg's stderr in the message.
            throw MaycastError.audioWriteFailed(url, underlying: error)
        }
    }
}

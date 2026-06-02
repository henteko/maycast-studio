import Foundation
import MaycastCore

/// GUI-facing wrapper around MaycastCore mutating operations.
///
/// Each call opens the bundle fresh from disk, performs the operation, saves,
/// and returns a result. Callers should reload their `EpisodeBundle` state
/// after a successful call (the bundle on disk has changed).
///
/// The struct itself is `Sendable` and **not** actor-isolated so its
/// CPU/IO-heavy methods can be invoked from `Task.detached(...)` to keep the
/// main actor responsive during apply/mix/polish. Only `transcribeStreaming`
/// retains an explicit `@MainActor` annotation because its callback updates
/// SwiftUI state.
/// All compute-heavy methods are `nonisolated` so they execute off the
/// main actor when invoked from `Task.detached(...)`. The project sets
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so without an explicit opt-out
/// these would inherit MainActor and block the UI thread.
nonisolated struct OperationsService: Sendable {
    init() {}

    func runMix(
        bundleURL: URL,
        outputPath: String?,
        overlay: MixOverlaySettings? = nil
    ) throws -> (relativePath: String, duration: TimeInterval, byteSize: Int) {
        let bundle = try EpisodeBundle.open(at: bundleURL)
        guard !bundle.episode.tracks.isEmpty else {
            throw OperationsError.message("Episode has no tracks to mix.")
        }
        var buffers: [AudioBuffer] = []
        for track in bundle.episode.tracks {
            let trackURL = bundleURL.appendingPathComponent(track.current)
            buffers.append(try AudioIO.read(from: trackURL))
        }
        let voiceMaster = try AudioIO.mixParallel(buffers)

        // Resolve overlay settings: caller-supplied snapshot overrides the
        // bundle's persisted MixConfig.
        let resolved = overlay ?? MixOverlaySettings(
            introPath: bundle.episode.mix.intro,
            outroPath: bundle.episode.mix.outro,
            introOffsetSec: bundle.episode.mix.introOffsetSec,
            outroOffsetSec: bundle.episode.mix.outroOffsetSec,
            duckingGainDB: bundle.episode.mix.duckingGainDB,
            duckingFadeSec: bundle.episode.mix.duckingFadeSec
        )

        let introBuffer: AudioBuffer? = try resolved.introPath
            .map(bundleURL.appendingPathComponent)
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            .map { try AudioIO.read(from: $0) }
        let outroBuffer: AudioBuffer? = try resolved.outroPath
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
                introOffsetSec: resolved.introOffsetSec,
                outroOffsetSec: resolved.outroOffsetSec,
                duckingGainDB: resolved.duckingGainDB,
                duckingFadeSec: resolved.duckingFadeSec
            )
        }
        let outRel = outputPath ?? "exports/\(bundle.episode.id).m4a"
        let outURL = bundleURL.appendingPathComponent(outRel)

        // Shift voice-timeline chapters onto the final timeline by the intro
        // lead (matches composeFinalMix's masterStart), then embed them.
        let introDur = introBuffer?.duration ?? 0
        let introOffset = max(0, min(resolved.introOffsetSec, introDur))
        let voiceStartInFinal = max(0, introDur - introOffset)
        let totalDuration = finalMix.duration
        let exportChapters: [ExportChapter] = bundle.sortedChapters.compactMap { chapter in
            let shifted = chapter.start + voiceStartInFinal
            guard shifted <= totalDuration else { return nil }
            return ExportChapter(startSec: shifted, title: chapter.title)
        }

        let pipeline = AssetExportPipeline(audio: finalMix, chapters: exportChapters, format: .m4a)
        try pipeline.write(to: outURL)
        let attrs = try FileManager.default.attributesOfItem(atPath: outURL.path)
        let size = (attrs[.size] as? Int) ?? 0
        return (outRel, finalMix.duration, size)
    }

    // MARK: - Chapters

    /// Load the episode's chapters (sorted by start time).
    func loadChapters(bundleURL: URL) -> [Chapter] {
        (try? EpisodeBundle.open(at: bundleURL))?.sortedChapters ?? []
    }

    /// Replace and persist the episode's chapters.
    func saveChapters(bundleURL: URL, chapters: [Chapter]) throws {
        var bundle = try EpisodeBundle.open(at: bundleURL)
        bundle.setChapters(chapters)
        try bundle.save()
    }

    /// Generate chapters from the merged transcript and persist them, using
    /// Google Gemini. Falls back to the heuristic engine if no API key is set
    /// or the request fails (network / bad response) — so this never
    /// hard-fails. Pass the key loaded from the Keychain at the call site.
    func generateChapters(bundleURL: URL, apiKey: String?) async throws -> [Chapter] {
        var bundle = try EpisodeBundle.open(at: bundleURL)
        let segments = bundle.mergedTranscriptSegments()
        let chapters: [Chapter]
        if let apiKey, !apiKey.isEmpty {
            do {
                chapters = try await GeminiChapterEngine(apiKey: apiKey).generate(from: segments)
            } catch {
                // Surface why Gemini was skipped (e.g. network error, blocked) —
                // visible in Console under the app process.
                NSLog("[Maycast] Chapter generation fell back to heuristic: \(error)")
                chapters = ChapterGenerator.heuristic(from: segments)
            }
        } else {
            NSLog("[Maycast] Chapter generation: no Gemini API key, using heuristic")
            chapters = ChapterGenerator.heuristic(from: segments)
        }
        bundle.setChapters(chapters)
        try bundle.save()
        return chapters
    }

    /// Whether any track has a transcript to generate chapters from.
    func hasAnyTranscript(bundleURL: URL) -> Bool {
        guard let bundle = try? EpisodeBundle.open(at: bundleURL) else { return false }
        return !bundle.mergedTranscriptSegments().isEmpty
    }

    func runSliceApply(
        bundleURL: URL,
        trackID: String,
        arrangement: Arrangement,
        batchID: String? = nil
    ) throws -> String {
        var bundle = try EpisodeBundle.open(at: bundleURL)
        let track = try bundle.applySliceArrangement(
            trackID: trackID,
            newArrangement: arrangement,
            batchID: batchID
        )
        return track.current
    }

/// Read the arrangement file for a track's current generation, if present.
    func loadCurrentArrangement(bundleURL: URL, trackID: String) throws -> Arrangement? {
        let bundle = try EpisodeBundle.open(at: bundleURL)
        return try bundle.currentArrangement(forTrackID: trackID)
    }

    /// Convenience: read the duration of a track's current generation.
    func currentDuration(bundleURL: URL, trackID: String) throws -> TimeInterval {
        let bundle = try EpisodeBundle.open(at: bundleURL)
        guard let track = bundle.track(withID: trackID) else { return 0 }
        let buffer = try AudioIO.read(from: bundleURL.appendingPathComponent(track.current))
        return buffer.duration
    }

    // MARK: - Transcription

    /// Run SpeechAnalyzer-based transcription on one track and persist the result
    /// to the track's current `transcript.json` sidecar.
    func runTranscribe(bundleURL: URL, trackID: String, locale: Locale) async throws -> [TranscriptSegment] {
        let bundle = try EpisodeBundle.open(at: bundleURL)
        guard let track = bundle.track(withID: trackID) else {
            throw OperationsError.message("Track not found: \(trackID)")
        }
        guard let transcriptURL = bundle.currentTranscriptURL(forTrackID: trackID) else {
            throw OperationsError.message("Cannot resolve transcript URL for \(trackID)")
        }
        let audioURL = bundleURL.appendingPathComponent(track.current)
        let segments = try await Transcription.transcribe(audioURL: audioURL, locale: locale)
        try JSONCoders.encode(Transcript(segments: segments), to: transcriptURL)
        return segments
    }

    /// Run transcription on every track in the episode. Returns a map of
    /// trackID -> segments.
    func runTranscribeAll(bundleURL: URL, locale: Locale) async throws -> [String: [TranscriptSegment]] {
        let bundle = try EpisodeBundle.open(at: bundleURL)
        var results: [String: [TranscriptSegment]] = [:]
        for track in bundle.episode.tracks {
            results[track.id] = try await runTranscribe(
                bundleURL: bundleURL, trackID: track.id, locale: locale
            )
        }
        return results
    }

    /// Load the current transcript for a track (returns empty segments if none).
    func loadCurrentTranscript(bundleURL: URL, trackID: String) -> [TranscriptSegment] {
        guard let bundle = try? EpisodeBundle.open(at: bundleURL),
              let url = bundle.currentTranscriptURL(forTrackID: trackID),
              FileManager.default.fileExists(atPath: url.path),
              let transcript = try? JSONCoders.decode(Transcript.self, from: url)
        else { return [] }
        return transcript.segments
    }

    /// Streaming transcription. Calls `onUpdate` repeatedly with the current
    /// state of the track as the analyzer makes progress (status messages,
    /// then growing segment lists). On success, persists the final transcript
    /// to disk.
    @MainActor
    func transcribeStreaming(
        bundleURL: URL,
        trackID: String,
        locale: Locale,
        onUpdate: @MainActor @escaping (TrackTranscriptState) -> Void
    ) async {
        do {
            let bundle = try EpisodeBundle.open(at: bundleURL)
            guard let track = bundle.track(withID: trackID) else {
                onUpdate(.failed(message: "Track '\(trackID)' not found"))
                return
            }
            guard let transcriptURL = bundle.currentTranscriptURL(forTrackID: trackID) else {
                onUpdate(.failed(message: "Cannot resolve transcript URL for \(trackID)"))
                return
            }
            let audioURL = bundleURL.appendingPathComponent(track.current)

            var collected: [TranscriptSegment] = []
            for try await update in Transcription.transcribeStream(audioURL: audioURL, locale: locale) {
                switch update {
                case .status(let msg):
                    onUpdate(.generating(partialSegments: collected, status: msg))
                case .segments(let segs):
                    collected = segs
                    onUpdate(.generating(partialSegments: segs, status: nil))
                }
            }

            try? JSONCoders.encode(Transcript(segments: collected), to: transcriptURL)
            onUpdate(.populated(segments: collected))
        } catch {
            onUpdate(.failed(message: String(describing: error)))
        }
    }
}

enum OperationsError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let s): return s }
    }
}

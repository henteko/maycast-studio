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

    func runMix(bundleURL: URL, outputPath: String?) throws -> (relativePath: String, duration: TimeInterval, byteSize: Int) {
        let bundle = try EpisodeBundle.open(at: bundleURL)
        guard !bundle.episode.tracks.isEmpty else {
            throw OperationsError.message("Episode has no tracks to mix.")
        }
        var buffers: [AudioBuffer] = []
        for track in bundle.episode.tracks {
            let trackURL = bundleURL.appendingPathComponent(track.current)
            buffers.append(try AudioIO.read(from: trackURL))
        }
        let mixed = try AudioIO.mixParallel(buffers)
        let outRel = outputPath ?? "exports/\(bundle.episode.id).wav"
        let outURL = bundleURL.appendingPathComponent(outRel)
        try AudioIO.writeWAV(mixed, to: outURL)
        let attrs = try FileManager.default.attributesOfItem(atPath: outURL.path)
        let size = (attrs[.size] as? Int) ?? 0
        return (outRel, mixed.duration, size)
    }

    /// Apply Polish settings to multiple tracks in a single call.
    /// Each track receives an independent normalization to the target LUFS
    /// (per-track measurement & gain). Returns per-track results.
    func runPolishMulti(
        bundleURL: URL,
        trackIDs: [String],
        loudnessTarget: Double?,
        denoise: Bool = false
    ) throws -> [(trackID: String, generationPath: String, measuredLUFS: Double?)] {
        var bundle = try EpisodeBundle.open(at: bundleURL)
        var results: [(String, String, Double?)] = []
        var paramsDict: [String: JSONValue] = [:]
        if let target = loudnessTarget { paramsDict["loudness"] = .number(target) }
        if denoise { paramsDict["denoise"] = .bool(true) }
        let paramsJSON: JSONValue? = paramsDict.isEmpty ? nil : .object(paramsDict)

        for trackID in trackIDs {
            let track = try bundle.appendOperationGeneration(
                trackID: trackID,
                operation: "polish",
                params: paramsJSON
            ) { input in
                var output = input
                if denoise {
                    output = Denoise.process(output)
                }
                if let target = loudnessTarget {
                    output = Loudness.normalize(output, toTargetLUFS: target)
                }
                return output
            }
            let outBuffer = try AudioIO.read(from: bundleURL.appendingPathComponent(track.current))
            let measured = Loudness.integratedLUFS(outBuffer)
            results.append((trackID, track.current, measured))
        }
        return results
    }

    /// Cross-track silence removal (Phase 3.1). Creates one new generation
    /// per track if any common-silence regions were found.
    func runSilenceRemoval(
        bundleURL: URL,
        threshold: Float = 0.01,
        minDuration: Double = 0.6,
        padding: Double = 0.1
    ) throws -> [(trackID: String, generationPath: String)] {
        var bundle = try EpisodeBundle.open(at: bundleURL)
        return try bundle.applyCrossTrackSilenceRemoval(
            threshold: threshold,
            minDuration: minDuration,
            padding: padding
        )
    }

    func runSliceApply(bundleURL: URL, trackID: String, arrangement: Arrangement) throws -> String {
        var bundle = try EpisodeBundle.open(at: bundleURL)
        let track = try bundle.applySliceArrangement(trackID: trackID, newArrangement: arrangement)
        return track.current
    }

    /// Measure integrated LUFS of a track's current generation.
    func measureCurrentLUFS(bundleURL: URL, trackID: String) throws -> Double? {
        let bundle = try EpisodeBundle.open(at: bundleURL)
        guard let track = bundle.track(withID: trackID) else { return nil }
        let buffer = try AudioIO.read(from: bundleURL.appendingPathComponent(track.current))
        return Loudness.integratedLUFS(buffer)
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

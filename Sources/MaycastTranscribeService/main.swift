import Foundation
import MaycastCore
import MaycastIPC

ServiceHost.runAsync { request in
    guard request.operation == .transcribe else {
        return .failure("Unexpected operation \(request.operation.rawValue) for TranscribeService")
    }
    guard let trackID = request.trackID else {
        return .failure("transcribe requires a trackID")
    }

    // Locale defaults to ja-JP, overridable via params.locale.
    var localeID = "ja-JP"
    if case let .object(p) = request.params,
       case let .string(s)? = p["locale"] {
        localeID = s
    }
    let locale = Locale(identifier: localeID)

    let bundleURL = URL(fileURLWithPath: request.episodeBundlePath)
    let bundle = try EpisodeBundle.open(at: bundleURL)
    guard let track = bundle.track(withID: trackID) else {
        return .failure("track '\(trackID)' not found")
    }
    guard let transcriptURL = bundle.currentTranscriptURL(forTrackID: trackID) else {
        return .failure("could not resolve transcript URL for track '\(trackID)'")
    }

    let audioURL = bundleURL.appendingPathComponent(track.current)
    let segments: [TranscriptSegment]
    do {
        segments = try await Transcription.transcribe(audioURL: audioURL, locale: locale)
    } catch {
        return .failure("Transcription failed: \(error)")
    }

    let transcript = Transcript(segments: segments)
    try JSONCoders.encode(transcript, to: transcriptURL)

    return .ok(message: "Transcribed track '\(trackID)' — \(segments.count) segment(s)")
}

import Foundation
import MaycastCore
import MaycastIPC

ServiceHost.run { request in
    guard request.operation == .transcribe else {
        return .failure("Unexpected operation \(request.operation.rawValue) for TranscribeService")
    }
    guard let trackID = request.trackID else {
        return .failure("transcribe requires a trackID")
    }

    let bundleURL = URL(fileURLWithPath: request.episodeBundlePath)
    var bundle = try EpisodeBundle.open(at: bundleURL)
    guard bundle.track(withID: trackID) != nil else {
        return .failure("track '\(trackID)' not found")
    }

    // Stub: overwrite the current generation's transcript sidecar with a dummy entry.
    guard let transcriptURL = bundle.currentTranscriptURL(forTrackID: trackID) else {
        return .failure("could not resolve transcript URL for track '\(trackID)'")
    }
    let dummy = Transcript(segments: [
        TranscriptSegment(start: 0.0, end: 1.0, text: "[stub-transcript]")
    ])
    try JSONCoders.encode(dummy, to: transcriptURL)
    try bundle.save()

    return .ok(message: "Transcribed (stub) track '\(trackID)'")
}

import Foundation
import MaycastCore
import MaycastIPC

ServiceHost.run { request in
    guard request.operation == .mix else {
        return .failure("Unexpected operation \(request.operation.rawValue) for MixService")
    }

    let bundleURL = URL(fileURLWithPath: request.episodeBundlePath)
    let bundle = try EpisodeBundle.open(at: bundleURL)
    guard !bundle.episode.tracks.isEmpty else {
        return .failure("episode has no tracks to mix")
    }

    let outputRel = request.outputPath ?? "exports/\(bundle.episode.id).wav"
    let outputURL = bundleURL.appendingPathComponent(outputRel)
    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )

    // Phase 1.3: parallel sum mix. Each track contributes its full audio,
    // mono is broadcast to both channels, output is stereo. Intro / Outro /
    // BGM ducking arrive in Phase 3.
    var buffers: [AudioBuffer] = []
    for track in bundle.episode.tracks {
        let trackURL = bundleURL.appendingPathComponent(track.current)
        if FileManager.default.fileExists(atPath: trackURL.path) {
            buffers.append(try AudioIO.read(from: trackURL))
        }
    }
    guard !buffers.isEmpty else {
        return .failure("no track audio found to mix")
    }
    let mixed = try AudioIO.mixParallel(buffers)
    try AudioIO.writeWAV(mixed, to: outputURL)

    return .ok(exportPath: outputRel, message: "Mixed (parallel sum) → \(outputRel)")
}

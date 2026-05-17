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
    let fm = FileManager.default
    try fm.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

    // Stub: concatenate the contents of each track's current file. Real implementation
    // will perform proper audio decoding/mixing in a later phase.
    var combined = Data()
    for track in bundle.episode.tracks {
        let current = bundleURL.appendingPathComponent(track.current)
        if fm.fileExists(atPath: current.path) {
            if let data = try? Data(contentsOf: current) {
                combined.append(data)
            }
        }
    }
    if combined.isEmpty {
        combined = Data("[stub-mix]".utf8)
    }
    try combined.write(to: outputURL, options: .atomic)

    return .ok(exportPath: outputRel, message: "Mixed (stub) → \(outputRel)")
}

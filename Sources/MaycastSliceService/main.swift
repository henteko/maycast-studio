import Foundation
import MaycastCore
import MaycastIPC

ServiceHost.run { request in
    guard request.operation == .slice else {
        return .failure("Unexpected operation \(request.operation.rawValue) for SliceService")
    }
    guard let trackID = request.trackID else {
        return .failure("slice requires a trackID")
    }

    let bundleURL = URL(fileURLWithPath: request.episodeBundlePath)
    var bundle = try EpisodeBundle.open(at: bundleURL)
    let track = try bundle.appendOperationGeneration(
        trackID: trackID,
        operation: "slice",
        params: request.params
    )
    return .ok(generationPath: track.current, message: "Sliced (stub) track '\(trackID)'")
}

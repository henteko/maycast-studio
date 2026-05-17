import Foundation
import MaycastCore
import MaycastIPC

ServiceHost.run { request in
    guard request.operation == .polish else {
        return .failure("Unexpected operation \(request.operation.rawValue) for PolishService")
    }
    guard let trackID = request.trackID else {
        return .failure("polish requires a trackID")
    }

    let bundleURL = URL(fileURLWithPath: request.episodeBundlePath)
    var bundle = try EpisodeBundle.open(at: bundleURL)
    let track = try bundle.appendOperationGeneration(
        trackID: trackID,
        operation: "polish",
        params: request.params
    )
    return .ok(generationPath: track.current, message: "Polished (stub) track '\(trackID)'")
}

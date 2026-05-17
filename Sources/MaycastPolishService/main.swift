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

    // Extract per-effect parameters from the params object.
    var loudnessTarget: Double?
    if case let .object(paramsDict)? = request.params {
        if case let .number(n)? = paramsDict["loudness"] { loudnessTarget = n }
        else if case let .integer(i)? = paramsDict["loudness"] { loudnessTarget = Double(i) }
    }

    let bundleURL = URL(fileURLWithPath: request.episodeBundlePath)
    var bundle = try EpisodeBundle.open(at: bundleURL)
    let track = try bundle.appendOperationGeneration(
        trackID: trackID,
        operation: "polish",
        params: request.params
    ) { input in
        var output = input
        if let target = loudnessTarget {
            output = Loudness.normalize(output, toTargetLUFS: target)
        }
        return output
    }

    var messageParts: [String] = []
    if let target = loudnessTarget { messageParts.append(String(format: "loudness → %.1f LUFS", target)) }
    let message = messageParts.isEmpty ? "Polished (no-op) track '\(trackID)'"
                                       : "Polished (\(messageParts.joined(separator: ", "))) track '\(trackID)'"
    return .ok(generationPath: track.current, message: message)
}

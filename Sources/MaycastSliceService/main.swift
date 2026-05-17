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
    guard case let .object(paramsDict)? = request.params else {
        return .failure("slice requires params object (subOp, ...)")
    }
    guard case let .string(subOp)? = paramsDict["subOp"] else {
        return .failure("slice requires params.subOp")
    }

    let bundleURL = URL(fileURLWithPath: request.episodeBundlePath)
    var bundle = try EpisodeBundle.open(at: bundleURL)
    guard let arrangement = try bundle.currentArrangement(forTrackID: trackID) else {
        return .failure("track '\(trackID)' has no current arrangement (was it imported?)")
    }

    let newArrangement: Arrangement
    switch subOp {
    case "split":
        guard case let .string(clipID)? = paramsDict["clipID"] else {
            return .failure("split requires params.clipID")
        }
        guard let at = numericValue(paramsDict["at"]) else {
            return .failure("split requires params.at (number)")
        }
        newArrangement = arrangement.splitting(clipID: clipID, atTimeline: at)
        if newArrangement == arrangement {
            return .failure("split had no effect — check clipID and that 'at' is strictly inside the clip")
        }

    case "delete":
        guard case let .string(clipID)? = paramsDict["clipID"] else {
            return .failure("delete requires params.clipID")
        }
        newArrangement = arrangement.deleting(clipID: clipID)
        if newArrangement == arrangement {
            return .failure("delete had no effect — clip '\(clipID)' not found")
        }

    case "move":
        guard case let .string(clipID)? = paramsDict["clipID"] else {
            return .failure("move requires params.clipID")
        }
        guard let to = numericValue(paramsDict["to"]) else {
            return .failure("move requires params.to (number)")
        }
        newArrangement = arrangement.moving(clipID: clipID, toTimeline: to)
        if newArrangement == arrangement {
            return .failure("move had no effect — clip '\(clipID)' not found")
        }

    case "apply":
        guard let arrangementValue = paramsDict["arrangement"] else {
            return .failure("apply requires params.arrangement")
        }
        // Re-encode the JSONValue and decode it as Arrangement.
        let encoder = JSONCoders.makeEncoder()
        let decoder = JSONCoders.makeDecoder()
        do {
            let data = try encoder.encode(arrangementValue)
            newArrangement = try decoder.decode(Arrangement.self, from: data)
        } catch {
            return .failure("apply: failed to decode arrangement: \(error)")
        }

    default:
        return .failure("unknown slice subOp '\(subOp)'")
    }

    let track = try bundle.applySliceArrangement(
        trackID: trackID,
        newArrangement: newArrangement,
        params: request.params
    )
    return .ok(generationPath: track.current, message: "Sliced (\(subOp)) track '\(trackID)'")
}

private func numericValue(_ value: JSONValue?) -> Double? {
    switch value {
    case .number(let n): return n
    case .integer(let i): return Double(i)
    default: return nil
    }
}

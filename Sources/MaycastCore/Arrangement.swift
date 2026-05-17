import Foundation

// MARK: - Clip

/// A single contiguous piece of source audio placed on a track timeline.
///
/// - `sourceStart..sourceEnd` is the range within the *source* audio.
/// - `timelineStart` is where the clip is placed on the *output* timeline.
/// - Gaps between clips render as silence (no ripple on delete).
public struct Clip: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var sourceStart: Double
    public var sourceEnd: Double
    public var timelineStart: Double

    public init(id: String = UUID().uuidString,
                sourceStart: Double,
                sourceEnd: Double,
                timelineStart: Double) {
        self.id = id
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.timelineStart = timelineStart
    }

    public var duration: Double { max(0, sourceEnd - sourceStart) }
    public var timelineEnd: Double { timelineStart + duration }
}

// MARK: - Arrangement

/// Ordered list of clips that defines the editing state of a single track.
public struct Arrangement: Codable, Sendable, Equatable {
    public var clips: [Clip]

    public init(clips: [Clip] = []) {
        self.clips = clips
    }

    /// The end-of-timeline position (= the longest clip's `timelineEnd`).
    public var totalDuration: Double {
        clips.map(\.timelineEnd).max() ?? 0
    }

    /// Convenience: a single full-length clip covering the whole source.
    public static func single(sourceDuration: Double) -> Arrangement {
        Arrangement(clips: [
            Clip(sourceStart: 0, sourceEnd: sourceDuration, timelineStart: 0)
        ])
    }
}

// MARK: - Operations

extension Arrangement {
    /// Split the clip with `clipID` at the given timeline time, producing two
    /// clips that abut at the split point. No-op if the time falls outside the
    /// clip or the clip is not found.
    public func splitting(clipID: String, atTimeline timelineTime: Double) -> Arrangement {
        var newClips: [Clip] = []
        for clip in clips {
            guard clip.id == clipID,
                  timelineTime > clip.timelineStart,
                  timelineTime < clip.timelineEnd
            else {
                newClips.append(clip)
                continue
            }
            let offset = timelineTime - clip.timelineStart
            let sourceSplit = clip.sourceStart + offset
            newClips.append(Clip(
                sourceStart: clip.sourceStart,
                sourceEnd: sourceSplit,
                timelineStart: clip.timelineStart
            ))
            newClips.append(Clip(
                sourceStart: sourceSplit,
                sourceEnd: clip.sourceEnd,
                timelineStart: timelineTime
            ))
        }
        return Arrangement(clips: newClips)
    }

    /// Remove a clip from the arrangement. Other clips keep their `timelineStart`
    /// (= the deleted clip's slot becomes silence; **no ripple**).
    public func deleting(clipID: String) -> Arrangement {
        Arrangement(clips: clips.filter { $0.id != clipID })
    }

    /// Move a clip to a new `timelineStart`. Callers are responsible for any
    /// snapping logic; this method only updates the value.
    public func moving(clipID: String, toTimeline newStart: Double) -> Arrangement {
        var newClips = clips
        if let idx = newClips.firstIndex(where: { $0.id == clipID }) {
            newClips[idx].timelineStart = newStart
        }
        return Arrangement(clips: newClips)
    }
}

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

    /// Whether applying this arrangement reproduces the source unchanged — i.e.
    /// the clips, in timeline order, run contiguously from 0 with no source
    /// skips, no gaps, no reordering, and cover the whole `sourceDuration`.
    ///
    /// Used to skip the (expensive) video re-encode for slice operations that
    /// don't actually cut anything — e.g. a `split` that only adds a clip
    /// boundary, or any apply where the user split/merged but kept all content.
    public func reproducesSourceUnchanged(sourceDuration: Double, tolerance: Double = 0.001) -> Bool {
        guard sourceDuration > 0 else { return false }
        let ordered = clips.sorted { $0.timelineStart < $1.timelineStart }
        var cursorSource = 0.0
        var cursorTimeline = 0.0
        for clip in ordered {
            guard clip.sourceEnd >= clip.sourceStart else { return false }
            if abs(clip.timelineStart - cursorTimeline) > tolerance { return false }
            if abs(clip.sourceStart - cursorSource) > tolerance { return false }
            cursorSource = clip.sourceEnd
            cursorTimeline += clip.duration
        }
        return abs(cursorSource - sourceDuration) <= tolerance
            && abs(cursorTimeline - sourceDuration) <= tolerance
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

    /// Compose two arrangements so a chain of edits can be replayed against the
    /// **original** media in one pass — the basis of deferred video rendering.
    ///
    /// - `base` maps *original → current*: each clip's `sourceStart..sourceEnd`
    ///   is an original-media range, `timelineStart` its place on the current
    ///   timeline.
    /// - `top` maps *current → new*: each clip selects a current-timeline range
    ///   (`sourceStart..sourceEnd`) and places it at `timelineStart` on the new
    ///   timeline.
    ///
    /// The result maps *original → new*. Content removed by either step becomes
    /// a source skip (a cut); timeline gaps are preserved (rendered as "keep the
    /// picture rolling" by `VideoEdit`). Applying the result to the original
    /// video reproduces the whole edit chain.
    public static func compose(base: Arrangement, top: Arrangement) -> Arrangement {
        let tol = 0.0005
        let baseClips = base.clips.sorted { $0.timelineStart < $1.timelineStart }
        var result: [Clip] = []
        for topClip in top.clips.sorted(by: { $0.timelineStart < $1.timelineStart }) {
            let curStart = topClip.sourceStart
            let curEnd = topClip.sourceEnd
            for b in baseClips {
                let bCurStart = b.timelineStart
                let bCurEnd = b.timelineEnd
                let ovStart = max(curStart, bCurStart)
                let ovEnd = min(curEnd, bCurEnd)
                guard ovEnd - ovStart > tol else { continue }
                let origStart = b.sourceStart + (ovStart - bCurStart)
                let origEnd = b.sourceStart + (ovEnd - bCurStart)
                let newStart = topClip.timelineStart + (ovStart - curStart)
                result.append(Clip(sourceStart: origStart, sourceEnd: origEnd, timelineStart: newStart))
            }
        }
        return Arrangement(clips: result)
    }
}

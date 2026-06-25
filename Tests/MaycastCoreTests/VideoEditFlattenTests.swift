import Testing
import Foundation
@testable import MaycastCore

@Suite("VideoEdit.flattenedRanges (tiles the timeline)")
struct VideoEditFlattenTests {
    private func sum(_ ranges: [(start: Double, end: Double)]) -> Double {
        ranges.reduce(0.0) { $0 + ($1.end - $1.start) }
    }

    @Test
    func contiguousClipsSumToTimeline() {
        let arr = Arrangement(clips: [
            Clip(sourceStart: 0, sourceEnd: 10, timelineStart: 0),
            Clip(sourceStart: 40, sourceEnd: 60, timelineStart: 10),
        ])
        let ranges = VideoEdit.flattenedRanges(arr)
        #expect(abs(sum(ranges) - arr.totalDuration) < 1e-6)   // 30
    }

    @Test
    func timelineGapIsFilled() {
        let arr = Arrangement(clips: [
            Clip(sourceStart: 0, sourceEnd: 10, timelineStart: 0),
            Clip(sourceStart: 50, sourceEnd: 60, timelineStart: 20), // gap 10–20
        ])
        let ranges = VideoEdit.flattenedRanges(arr)
        #expect(abs(sum(ranges) - arr.totalDuration) < 1e-6)   // 30
    }

    /// Overlapping clips must not duplicate content — the ranges still tile the
    /// timeline exactly (this is the bug that made renders 3–4× too long).
    @Test
    func overlappingClipsAreClampedToTimeline() {
        let arr = Arrangement(clips: [
            Clip(sourceStart: 0, sourceEnd: 30, timelineStart: 0),   // ends at 30
            Clip(sourceStart: 40, sourceEnd: 60, timelineStart: 20), // overlaps 20–30
        ])
        #expect(arr.totalDuration == 40)
        let ranges = VideoEdit.flattenedRanges(arr)
        #expect(abs(sum(ranges) - 40) < 1e-6, "ranges must tile the 40s timeline, not 50s")
    }

    @Test
    func fullyCoveredClipIsDropped() {
        let arr = Arrangement(clips: [
            Clip(sourceStart: 0, sourceEnd: 30, timelineStart: 0),
            Clip(sourceStart: 5, sourceEnd: 10, timelineStart: 5),   // entirely inside the first
        ])
        let ranges = VideoEdit.flattenedRanges(arr)
        #expect(abs(sum(ranges) - arr.totalDuration) < 1e-6)   // 30
    }
}

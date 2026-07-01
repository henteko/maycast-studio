import Testing
import Foundation
@testable import MaycastCore

/// The lip-sync fix: each output segment's frame count is pinned to the audio
/// timeline via error feedback, so cut points never drift more than half a
/// frame from where the (sample-accurate) audio cuts — no accumulation.
@Suite("VideoEdit.frameSegments (frame-accurate, non-accumulating)")
struct VideoEditFrameSegmentsTests {
    private let fps = 2225600.0 / 92737.0   // the real episode's ~23.999 fps

    /// Cumulative output frames after every segment must equal
    /// round(cumulativeTimeline * fps) exactly — that's what keeps the picture
    /// locked to the audio with no drift, however many cuts there are.
    @Test
    func cumulativeFramesTrackTheTimelineExactly() {
        // 39 contiguous fractional segments (mirrors the real 39-clip episode).
        var ranges: [(start: Double, end: Double)] = []
        var src = 0.0
        for i in 0..<39 {
            let keep = 0.9 + Double(i % 7) * 0.37   // varied, non-frame-aligned
            ranges.append((src, src + keep))
            src += keep + 0.21                       // a cut between each
        }
        let segs = VideoEdit.frameSegments(ranges, fps: fps)

        var cumFrames = 0
        var cumTimeline = 0.0
        for (i, r) in ranges.enumerated() {
            cumFrames += segs[i].frameCount
            cumTimeline += (r.end - r.start)
            let expected = Int((cumTimeline * fps).rounded())
            #expect(cumFrames == expected,
                    "drift at segment \(i): \(cumFrames) frames vs expected \(expected)")
        }
        // ...and never off by more than half a frame in time.
        let totalTimeline = cumTimeline
        let videoDuration = Double(cumFrames) / fps
        #expect(abs(videoDuration - totalTimeline) < 0.5 / fps)
    }

    /// Each segment shows the source frame nearest its cut start (sub-frame
    /// accurate), so within-clip picture matches the audio it's muxed against.
    @Test
    func startFrameSnapsToTheSourceCut() {
        let ranges: [(start: Double, end: Double)] = [(13.381, 30.245), (30.645, 115.676)]
        let segs = VideoEdit.frameSegments(ranges, fps: fps)
        #expect(segs[0].startFrame == Int((13.381 * fps).rounded()))
        #expect(segs[1].startFrame == Int((30.645 * fps).rounded()))
    }

    /// When the video stream starts after the audio (camera lags the mic), the
    /// source cut must map to the video frame *actually presented* at that audio
    /// time — i.e. shifted back by `sourceStartTime`. Without this the whole
    /// picture desyncs by the offset (the ep12 kuniwak bug: ~2.17s).
    @Test
    func startFrameCompensatesForVideoStartTime() {
        let ranges: [(start: Double, end: Double)] = [(31.125, 60.0)]
        let f = 30.0
        let offset = 2.167795
        let plain = VideoEdit.frameSegments(ranges, fps: f)
        let shifted = VideoEdit.frameSegments(ranges, fps: f, sourceStartTime: offset)
        #expect(plain[0].startFrame == Int((31.125 * f).rounded()))           // 934
        #expect(shifted[0].startFrame == Int(((31.125 - offset) * f).rounded())) // 869
        // Same output length regardless of offset — only the source anchor moves.
        #expect(plain[0].frameCount == shifted[0].frameCount)
    }

    /// A cut that begins before the video stream exists clamps to frame 0 rather
    /// than a negative index.
    @Test
    func startFrameClampsAtZeroBeforeVideoBegins() {
        let ranges: [(start: Double, end: Double)] = [(0.5, 3.0)]
        let segs = VideoEdit.frameSegments(ranges, fps: 30, sourceStartTime: 2.0)
        #expect(segs[0].startFrame == 0)
    }

    /// Sub-frame slivers collapse to nothing rather than emitting empty segments.
    @Test
    func subFrameRangesAreDropped() {
        let ranges: [(start: Double, end: Double)] = [(0, 0.0002), (1.0, 3.0)]
        let segs = VideoEdit.frameSegments(ranges, fps: fps)
        #expect(segs.allSatisfy { $0.frameCount > 0 })
    }
}

import Testing
import Foundation
@testable import MaycastCore

@Suite("Arrangement.compose (deferred video edit chaining)")
struct ArrangementComposeTests {
    private func clip(_ s: Double, _ e: Double, at t: Double) -> Clip {
        Clip(sourceStart: s, sourceEnd: e, timelineStart: t)
    }

    @Test
    func identityBaseReturnsTop() {
        let base = Arrangement.single(sourceDuration: 10)   // original == current
        let top = Arrangement(clips: [clip(0, 2, at: 0), clip(4, 10, at: 2)]) // delete 2–4
        let out = Arrangement.compose(base: base, top: top)
        #expect(out.clips.count == 2)
        #expect(out.clips[0].sourceStart == 0 && out.clips[0].sourceEnd == 2 && out.clips[0].timelineStart == 0)
        #expect(out.clips[1].sourceStart == 4 && out.clips[1].sourceEnd == 10 && out.clips[1].timelineStart == 2)
    }

    @Test
    func chainedDeletesMapBackToOriginal() {
        // First delete removed original 2–4 → current is 8s long, mapping:
        //   current[0,2] → original[0,2], current[2,8] → original[4,10]
        let base = Arrangement(clips: [clip(0, 2, at: 0), clip(4, 10, at: 2)])
        // Second delete on the current timeline: remove current 1–3, keep
        //   current[0,1] and current[3,8].
        let top = Arrangement(clips: [clip(0, 1, at: 0), clip(3, 8, at: 1)])
        let out = Arrangement.compose(base: base, top: top).clips.sorted { $0.timelineStart < $1.timelineStart }

        // Net kept original ranges: 0–1 and 5–10, contiguous on the new timeline.
        #expect(out.count == 2)
        #expect(abs(out[0].sourceStart - 0) < 1e-6 && abs(out[0].sourceEnd - 1) < 1e-6 && abs(out[0].timelineStart - 0) < 1e-6)
        #expect(abs(out[1].sourceStart - 5) < 1e-6 && abs(out[1].sourceEnd - 10) < 1e-6 && abs(out[1].timelineStart - 1) < 1e-6)
    }

    @Test
    func timelineGapInTopIsPreserved() {
        // base identity; top moves a clip later, leaving a gap [2,3] on the new
        // timeline → the result has the same gap (no clip covering it).
        let base = Arrangement.single(sourceDuration: 10)
        let top = Arrangement(clips: [clip(0, 2, at: 0), clip(2, 4, at: 3)])
        let out = Arrangement.compose(base: base, top: top).clips.sorted { $0.timelineStart < $1.timelineStart }
        #expect(out.count == 2)
        #expect(out[0].timelineStart == 0 && out[0].timelineEnd == 2)
        #expect(out[1].timelineStart == 3)   // gap 2–3 preserved
    }
}

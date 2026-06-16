import Testing
import Foundation
@testable import MaycastCore

@Suite("Auphonic cut list → kept arrangement")
struct AuphonicCutListTests {
    @Test
    func parsesAudacityRegionsAndMergesOverlaps() {
        let text = """
        2.0\t3.0\tsilence
        5.0\t6.5\tfiller
        6.0\t7.0\tsilence
        bad line
        \t\t
        """
        let regions = AuphonicCutList.parseAudacityRegions(text)
        // 5.0–6.5 and 6.0–7.0 overlap → merged to 5.0–7.0.
        #expect(regions == [
            AuphonicCutList.Region(start: 2.0, end: 3.0),
            AuphonicCutList.Region(start: 5.0, end: 7.0),
        ])
    }

    @Test
    func keptArrangementIsComplementLaidOutContiguously() {
        // Remove 2–3 and 5–7 from a 10s input → keep 0–2, 3–5, 7–10.
        let removed = [
            AuphonicCutList.Region(start: 2.0, end: 3.0),
            AuphonicCutList.Region(start: 5.0, end: 7.0),
        ]
        let arr = AuphonicCutList.keptArrangement(removed: removed, totalDuration: 10.0)
        #expect(arr.clips.count == 3)
        // Source spans = the kept regions.
        #expect(arr.clips[0].sourceStart == 0.0 && arr.clips[0].sourceEnd == 2.0)
        #expect(arr.clips[1].sourceStart == 3.0 && arr.clips[1].sourceEnd == 5.0)
        #expect(arr.clips[2].sourceStart == 7.0 && arr.clips[2].sourceEnd == 10.0)
        // Timeline is contiguous (no gaps) — total kept = 2 + 2 + 3 = 7s.
        #expect(arr.clips[0].timelineStart == 0.0)
        #expect(arr.clips[1].timelineStart == 2.0)
        #expect(arr.clips[2].timelineStart == 4.0)
        #expect(abs(arr.totalDuration - 7.0) < 0.0001)
    }

    @Test
    func noCutsKeepsWholeInput() {
        let arr = AuphonicCutList.keptArrangement(removed: [], totalDuration: 8.0)
        #expect(arr.clips.count == 1)
        #expect(arr.clips[0].sourceStart == 0.0)
        #expect(abs(arr.clips[0].sourceEnd - 8.0) < 0.0001)
        #expect(arr.clips[0].timelineStart == 0.0)
    }

    @Test
    func reproducesSourceUnchangedDetectsIdentityVsRealCuts() {
        // Single full clip → identity.
        #expect(Arrangement.single(sourceDuration: 4.0).reproducesSourceUnchanged(sourceDuration: 4.0))
        // Split into two abutting clips covering the whole source → still identity.
        let split = Arrangement(clips: [
            Clip(id: "a", sourceStart: 0, sourceEnd: 1.5, timelineStart: 0),
            Clip(id: "b", sourceStart: 1.5, sourceEnd: 4.0, timelineStart: 1.5),
        ])
        #expect(split.reproducesSourceUnchanged(sourceDuration: 4.0))
        // A real cut (drop the middle) → not identity.
        let cut = Arrangement(clips: [
            Clip(id: "a", sourceStart: 0, sourceEnd: 1.0, timelineStart: 0),
            Clip(id: "b", sourceStart: 2.0, sourceEnd: 4.0, timelineStart: 1.0),
        ])
        #expect(!cut.reproducesSourceUnchanged(sourceDuration: 4.0))
        // A move that introduces a leading gap → not identity.
        let moved = Arrangement(clips: [Clip(id: "a", sourceStart: 0, sourceEnd: 4.0, timelineStart: 5.0)])
        #expect(!moved.reproducesSourceUnchanged(sourceDuration: 4.0))
        // Keeping only the first half → not identity.
        let trimmed = Arrangement(clips: [Clip(id: "a", sourceStart: 0, sourceEnd: 2.0, timelineStart: 0)])
        #expect(!trimmed.reproducesSourceUnchanged(sourceDuration: 4.0))
    }

    @Test
    func leadingAndTrailingCutsHandled() {
        // Remove 0–1 (leading) and 9–10 (trailing) from 10s → keep 1–9.
        let removed = [
            AuphonicCutList.Region(start: 0.0, end: 1.0),
            AuphonicCutList.Region(start: 9.0, end: 10.0),
        ]
        let arr = AuphonicCutList.keptArrangement(removed: removed, totalDuration: 10.0)
        #expect(arr.clips.count == 1)
        #expect(arr.clips[0].sourceStart == 1.0 && arr.clips[0].sourceEnd == 9.0)
        #expect(arr.clips[0].timelineStart == 0.0)
    }
}

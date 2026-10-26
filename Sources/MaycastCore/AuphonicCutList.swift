import Foundation

/// Parsing of Auphonic "Cut List" output files and conversion of the removed
/// regions into a Maycast `Arrangement`.
///
/// When Polish runs as a multitrack production with the silence / filler /
/// cough cutters on, Auphonic cuts every track at the *same* timeline points
/// (so the speakers stay aligned). It can additionally emit a cut list — the
/// list of removed `[start, end)` regions on the **input** timeline — which we
/// request as `{"format": "cut-list", "ending": "AudacityRegions.txt"}`.
///
/// We turn those removed regions into the complementary *kept* regions and lay
/// them out contiguously: that's exactly the `Arrangement` that, applied to a
/// speaker's video via `VideoEdit`, reproduces the same cuts Auphonic applied
/// to the audio — keeping picture and cleaned audio in sync.
///
/// Cleanvoice's `timeline_audacity` marker file (requested with
/// `export_timestamps`) uses the same tab-separated format, so it goes through
/// the same parser — see `keptArrangement(removed:totalDuration:matchingOutputDuration:)`.
public enum AuphonicCutList {
    public struct Region: Sendable, Equatable {
        public var start: Double
        public var end: Double
        public init(start: Double, end: Double) {
            self.start = start
            self.end = end
        }
    }

    /// Parse an Auphonic "AudacityRegions.txt" cut list: tab-separated lines of
    /// `start<TAB>end<TAB>label`, timestamps in seconds. Lines that don't carry
    /// two parseable timestamps are skipped. Returned regions are the *removed*
    /// spans, sorted and with any overlaps merged.
    public static func parseAudacityRegions(_ text: String) -> [Region] {
        var regions: [Region] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let cols = rawLine.split(separator: "\t", omittingEmptySubsequences: false)
            guard cols.count >= 2,
                  let start = Double(cols[0].trimmingCharacters(in: .whitespaces)),
                  let end = Double(cols[1].trimmingCharacters(in: .whitespaces)),
                  end > start
            else { continue }
            regions.append(Region(start: start, end: end))
        }
        return merge(regions)
    }

    /// Merge overlapping / touching regions into a sorted, disjoint set.
    static func merge(_ regions: [Region]) -> [Region] {
        let sorted = regions.sorted { $0.start < $1.start }
        var merged: [Region] = []
        for r in sorted {
            if let last = merged.last, r.start <= last.end {
                merged[merged.count - 1].end = max(last.end, r.end)
            } else {
                merged.append(r)
            }
        }
        return merged
    }

    /// Build the Arrangement of KEPT segments (the complement of `removed`
    /// within `[0, totalDuration)`), laid out contiguously on the output
    /// timeline. Applying this to the input video reproduces Auphonic's cuts.
    public static func keptArrangement(removed: [Region], totalDuration: Double) -> Arrangement {
        guard totalDuration > 0 else { return Arrangement(clips: []) }
        let cuts = merge(removed)
        var clips: [Clip] = []
        var cursorSource = 0.0      // position on the input timeline
        var cursorTimeline = 0.0    // position on the (contiguous) output timeline
        var index = 0

        func appendKept(from: Double, to: Double) {
            let s = max(0, from)
            let e = min(totalDuration, to)
            guard e - s > 0.0005 else { return }
            clips.append(Clip(id: "kept\(index)", sourceStart: s, sourceEnd: e, timelineStart: cursorTimeline))
            index += 1
            cursorTimeline += (e - s)
        }

        for region in cuts {
            appendKept(from: cursorSource, to: region.start)
            cursorSource = max(cursorSource, region.end)
        }
        appendKept(from: cursorSource, to: totalDuration)

        return Arrangement(clips: clips)
    }

    /// Like `keptArrangement(removed:totalDuration:)`, but adjusted so the kept
    /// length equals `outputDuration` — the length of the cleaned audio.
    ///
    /// Cleanvoice's cut list reports each removed span *including* the short
    /// crossfade it blends across the cut (~50 ms), so the audio loses a bit
    /// less than the regions say. Left alone that error accumulates over many
    /// cuts and drifts the picture out of lip sync. The surplus is split evenly
    /// across the regions, each shrinking around its interior (a region at the
    /// very start / end only moves its inner edge).
    ///
    /// - Throws: `CutListMismatch` when the regions can't explain the length
    ///   change (more than `tolerancePerCut` per region, or a length change
    ///   with no regions) — rather than writing a desynced video edit.
    public static func keptArrangement(
        removed: [Region],
        totalDuration: Double,
        matchingOutputDuration outputDuration: Double,
        tolerancePerCut: Double = 0.25
    ) throws -> Arrangement {
        var cuts = merge(removed)
            .map { Region(start: max(0, $0.start), end: min(totalDuration, $0.end)) }
            .filter { $0.end - $0.start > 0.0005 }
        let removedTotal = cuts.reduce(0) { $0 + ($1.end - $1.start) }
        // Positive ⇒ the audio kept more than the regions imply.
        let surplus = outputDuration - (totalDuration - removedTotal)

        if cuts.isEmpty {
            guard abs(surplus) <= tolerancePerCut else {
                throw CutListMismatch(expectedDuration: totalDuration, outputDuration: outputDuration, regions: 0)
            }
            return keptArrangement(removed: [], totalDuration: totalDuration)
        }
        let perCut = surplus / Double(cuts.count)
        guard abs(perCut) <= tolerancePerCut else {
            throw CutListMismatch(
                expectedDuration: totalDuration - removedTotal,
                outputDuration: outputDuration,
                regions: cuts.count
            )
        }

        let edgeEpsilon = 0.0005
        for i in cuts.indices {
            let atStart = cuts[i].start <= edgeEpsilon
            let atEnd = cuts[i].end >= totalDuration - edgeEpsilon
            switch (atStart, atEnd) {
            case (true, true): break                    // whole track removed; nothing to give back
            case (true, false): cuts[i].end -= perCut
            case (false, true): cuts[i].start += perCut
            case (false, false):
                cuts[i].start += perCut / 2
                cuts[i].end -= perCut / 2
            }
            if cuts[i].end < cuts[i].start { cuts[i].end = cuts[i].start }
        }
        return keptArrangement(removed: cuts, totalDuration: totalDuration)
    }

    public struct CutListMismatch: Error, CustomStringConvertible, Sendable {
        public var expectedDuration: Double
        public var outputDuration: Double
        public var regions: Int

        public var description: String {
            String(
                format: "The cut list (%d region%@, %.2fs kept) doesn't match the cleaned audio (%.2fs), so the video can't follow the cuts safely.",
                regions, regions == 1 ? "" : "s", expectedDuration, outputDuration
            )
        }
    }
}

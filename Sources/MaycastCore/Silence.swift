import Foundation

/// Silence detection and editing helpers used by cross-track silence removal
/// (Phase 3.1). All functions are pure: they operate on `AudioBuffer` values
/// and return new ones without touching the file system.
public enum Silence {
    /// A half-open time interval `[start, end)` in seconds within an audio
    /// buffer or arrangement.
    public struct Range: Hashable, Sendable {
        public var start: Double
        public var end: Double
        public init(start: Double, end: Double) {
            self.start = start
            self.end = end
        }
        public var duration: Double { max(0, end - start) }
    }

    // MARK: - Detection

    /// Find regions in `buffer` where the per-sample maximum amplitude (across
    /// channels) stays below `threshold` for at least `minDuration` seconds.
    ///
    /// `threshold` is a linear amplitude (0.0–1.0), not dBFS. A typical value
    /// for "below -40 dBFS" is 0.01.
    public static func detectSilentRegions(
        _ buffer: AudioBuffer,
        threshold: Float = 0.01,
        minDuration: Double = 0.5
    ) -> [Range] {
        guard buffer.frameCount > 0, !buffer.samples.isEmpty else { return [] }
        let sr = buffer.sampleRate
        let frameCount = buffer.frameCount
        let channelCount = buffer.channelCount

        var spans: [Range] = []
        var spanStartFrame: Int? = nil

        for i in 0..<frameCount {
            var maxAbs: Float = 0
            for ch in 0..<channelCount {
                let v = abs(buffer.samples[ch][i])
                if v > maxAbs { maxAbs = v }
            }
            if maxAbs <= threshold {
                if spanStartFrame == nil { spanStartFrame = i }
            } else if let start = spanStartFrame {
                appendIfLong(
                    start: start, end: i, sr: sr, min: minDuration, into: &spans
                )
                spanStartFrame = nil
            }
        }
        if let start = spanStartFrame {
            appendIfLong(
                start: start, end: frameCount, sr: sr, min: minDuration, into: &spans
            )
        }
        return spans
    }

    private static func appendIfLong(
        start: Int, end: Int, sr: Double, min: Double, into spans: inout [Range]
    ) {
        let dur = Double(end - start) / sr
        if dur >= min {
            spans.append(Range(start: Double(start) / sr, end: Double(end) / sr))
        }
    }

    // MARK: - Intersection

    /// Intersect N sets of ranges. Returns the spans where **every** input set
    /// has a covering range — i.e. the "all tracks silent" regions when each
    /// input is one track's silent regions.
    public static func intersect(_ trackRanges: [[Range]]) -> [Range] {
        guard let first = trackRanges.first else { return [] }
        if trackRanges.count == 1 { return mergeSorted(first.sorted { $0.start < $1.start }) }
        var acc = mergeSorted(first.sorted { $0.start < $1.start })
        for next in trackRanges.dropFirst() {
            acc = pairwiseIntersect(acc, mergeSorted(next.sorted { $0.start < $1.start }))
            if acc.isEmpty { return [] }
        }
        return acc
    }

    private static func pairwiseIntersect(_ a: [Range], _ b: [Range]) -> [Range] {
        var result: [Range] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            let s = max(a[i].start, b[j].start)
            let e = min(a[i].end, b[j].end)
            if s < e { result.append(Range(start: s, end: e)) }
            if a[i].end < b[j].end { i += 1 } else { j += 1 }
        }
        return result
    }

    private static func mergeSorted(_ ranges: [Range]) -> [Range] {
        var out: [Range] = []
        for r in ranges {
            if let last = out.last, r.start <= last.end {
                out[out.count - 1] = Range(start: last.start, end: max(last.end, r.end))
            } else {
                out.append(r)
            }
        }
        return out
    }

    // MARK: - Removal

    /// Return a new buffer with `ranges` removed and the surrounding audio
    /// concatenated. `padding` (seconds) shrinks each cut by that amount on
    /// each side, leaving a small breath at the boundaries so the resulting
    /// audio doesn't sound abrupt.
    public static func removeRanges(
        from buffer: AudioBuffer,
        ranges: [Range],
        padding: Double = 0.1
    ) -> AudioBuffer {
        guard !ranges.isEmpty else { return buffer }
        let sr = buffer.sampleRate
        let totalFrames = buffer.frameCount
        let channelCount = buffer.channelCount

        // Apply padding (shrink each cut) and merge any overlaps.
        let padded: [Range] = ranges
            .map { Range(start: $0.start + padding, end: $0.end - padding) }
            .filter { $0.end > $0.start }
        let cuts = mergeSorted(padded.sorted { $0.start < $1.start })
        if cuts.isEmpty { return buffer }

        // Build "keep" segments = the complement of `cuts`.
        var keepFrameRanges: [(Int, Int)] = []
        var cursor = 0
        for cut in cuts {
            let cutStart = max(0, min(totalFrames, Int((cut.start * sr).rounded())))
            let cutEnd = max(0, min(totalFrames, Int((cut.end * sr).rounded())))
            if cutStart > cursor {
                keepFrameRanges.append((cursor, cutStart))
            }
            cursor = max(cursor, cutEnd)
        }
        if cursor < totalFrames {
            keepFrameRanges.append((cursor, totalFrames))
        }

        // Concatenate the kept regions per channel.
        var outChannels: [[Float]] = Array(repeating: [], count: channelCount)
        for (s, e) in keepFrameRanges {
            guard e > s else { continue }
            for ch in 0..<channelCount {
                outChannels[ch].append(contentsOf: buffer.samples[ch][s..<e])
            }
        }
        return AudioBuffer(
            sampleRate: sr,
            channelCount: channelCount,
            samples: outChannels
        )
    }
}

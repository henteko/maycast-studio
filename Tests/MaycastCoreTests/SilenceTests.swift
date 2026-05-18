import Testing
import Foundation
@testable import MaycastCore

@Suite("Silence DSP")
struct SilenceTests {
    /// Build a planar AudioBuffer from a list of segments. A `.tone` segment
    /// is a sine wave; a `.silence` segment is zero. Used to construct
    /// deterministic inputs for the detector.
    private func makeBuffer(segments: [Segment], sampleRate: Double = 16000) -> AudioBuffer {
        var samples: [Float] = []
        for seg in segments {
            switch seg {
            case .silence(let dur):
                samples.append(contentsOf: repeatElement(0, count: Int(dur * sampleRate)))
            case .tone(let dur, let amp):
                let n = Int(dur * sampleRate)
                for i in 0..<n {
                    let t = Double(i) / sampleRate
                    samples.append(Float(amp * sin(2 * .pi * 440 * t)))
                }
            }
        }
        return AudioBuffer(sampleRate: sampleRate, channelCount: 1, samples: [samples])
    }

    private enum Segment {
        case silence(Double)
        case tone(Double, amp: Double)
    }

    // MARK: - detectSilentRegions

    @Test
    func detectsLeadingSilenceFollowedByTone() {
        let buffer = makeBuffer(segments: [
            .silence(1.0),
            .tone(1.0, amp: 0.3),
        ])
        let regions = Silence.detectSilentRegions(buffer, threshold: 0.01, minDuration: 0.3)
        #expect(regions.count == 1)
        if let r = regions.first {
            #expect(r.start < 0.05)
            #expect(r.end > 0.95 && r.end <= 1.05)
        }
    }

    @Test
    func skipsSilenceShorterThanMinDuration() {
        let buffer = makeBuffer(segments: [
            .tone(0.5, amp: 0.3),
            .silence(0.1),  // < minDuration 0.3
            .tone(0.5, amp: 0.3),
        ])
        let regions = Silence.detectSilentRegions(buffer, threshold: 0.01, minDuration: 0.3)
        #expect(regions.isEmpty)
    }

    @Test
    func detectsAllSilenceBuffer() {
        let buffer = makeBuffer(segments: [.silence(2.0)])
        let regions = Silence.detectSilentRegions(buffer, threshold: 0.01, minDuration: 0.3)
        #expect(regions.count == 1)
        if let r = regions.first {
            #expect(abs(r.start) < 0.01)
            #expect(abs(r.end - 2.0) < 0.05)
        }
    }

    // MARK: - intersect

    @Test
    func intersectOfDisjointRangesIsEmpty() {
        let a = [Silence.Range(start: 0, end: 1)]
        let b = [Silence.Range(start: 2, end: 3)]
        #expect(Silence.intersect([a, b]).isEmpty)
    }

    @Test
    func intersectOfOverlappingRangesReturnsOverlap() {
        let a = [Silence.Range(start: 1.0, end: 3.0)]
        let b = [Silence.Range(start: 2.0, end: 4.0)]
        let result = Silence.intersect([a, b])
        #expect(result.count == 1)
        if let r = result.first {
            #expect(abs(r.start - 2.0) < 1e-9)
            #expect(abs(r.end - 3.0) < 1e-9)
        }
    }

    @Test
    func intersectAcrossThreeTracksRequiresAllSilent() {
        // Track A: silent in 0-2 and 5-6
        // Track B: silent in 1-3 and 5.5-6
        // Track C: silent in 0.5-2.5 and 5-6
        // All-silent overlap: 1-2 (intersection of leading silences) + 5.5-6
        let a = [Silence.Range(start: 0, end: 2), Silence.Range(start: 5, end: 6)]
        let b = [Silence.Range(start: 1, end: 3), Silence.Range(start: 5.5, end: 6)]
        let c = [Silence.Range(start: 0.5, end: 2.5), Silence.Range(start: 5, end: 6)]
        let result = Silence.intersect([a, b, c])
        #expect(result.count == 2)
        if result.count >= 1 {
            #expect(abs(result[0].start - 1.0) < 1e-9)
            #expect(abs(result[0].end - 2.0) < 1e-9)
        }
        if result.count >= 2 {
            #expect(abs(result[1].start - 5.5) < 1e-9)
            #expect(abs(result[1].end - 6.0) < 1e-9)
        }
    }

    @Test
    func intersectOfSingleTrackReturnsItself() {
        let a = [Silence.Range(start: 1, end: 2), Silence.Range(start: 3, end: 4)]
        let result = Silence.intersect([a])
        #expect(result == a)
    }

    @Test
    func intersectOfEmptyInputIsEmpty() {
        #expect(Silence.intersect([]).isEmpty)
    }

    // MARK: - removeRanges

    @Test
    func removeRangesShortensBuffer() {
        // 3s buffer; remove 1.0–2.0; result should be 2.0s.
        let buffer = makeBuffer(segments: [
            .tone(1.0, amp: 0.3),
            .silence(1.0),
            .tone(1.0, amp: 0.3),
        ])
        let cut = Silence.removeRanges(
            from: buffer,
            ranges: [Silence.Range(start: 1.0, end: 2.0)],
            padding: 0
        )
        #expect(abs(cut.duration - 2.0) < 0.01)
    }

    @Test
    func removeRangesPaddingShrinksTheCut() {
        // 3s buffer; remove 1.0–2.0 with 0.1s padding → only the inner 1.1–1.9 is removed.
        let buffer = makeBuffer(segments: [
            .tone(1.0, amp: 0.3),
            .silence(1.0),
            .tone(1.0, amp: 0.3),
        ])
        let cut = Silence.removeRanges(
            from: buffer,
            ranges: [Silence.Range(start: 1.0, end: 2.0)],
            padding: 0.1
        )
        // Removed 0.8s → output is 2.2s.
        #expect(abs(cut.duration - 2.2) < 0.01)
    }

    @Test
    func removeRangesWithNoRangesIsIdentity() {
        let buffer = makeBuffer(segments: [.tone(1.0, amp: 0.3)])
        let cut = Silence.removeRanges(from: buffer, ranges: [], padding: 0)
        #expect(cut.samples == buffer.samples)
    }

    @Test
    func removeRangesPreservesStereo() {
        let sr: Double = 16000
        let n = Int(2.0 * sr)
        let chL = (0..<n).map { Float(0.3 * sin(2 * .pi * 440 * Double($0) / sr)) }
        let chR = (0..<n).map { Float(0.3 * sin(2 * .pi * 220 * Double($0) / sr)) }
        let buffer = AudioBuffer(sampleRate: sr, channelCount: 2, samples: [chL, chR])
        let cut = Silence.removeRanges(
            from: buffer,
            ranges: [Silence.Range(start: 0.5, end: 1.0)],
            padding: 0
        )
        #expect(cut.channelCount == 2)
        #expect(abs(cut.duration - 1.5) < 0.01)
    }
}

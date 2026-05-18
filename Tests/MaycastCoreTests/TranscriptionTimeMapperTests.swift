import Testing
import Foundation
import AVFoundation
@testable import MaycastCore

@Suite("Transcription time mapping (pre-trim approach)")
struct TranscriptionTimeMapperTests {
    private typealias VoicedRegion = Transcription.VoicedRegion
    private typealias VoicedTimeMapper = Transcription.VoicedTimeMapper

    @Test
    func mapperWithEmptyRegionsIsIdentity() {
        let mapper = VoicedTimeMapper(regions: [], paddingBetween: 0)
        #expect(mapper.fileTime(forConcat: 0.0) == 0.0)
        #expect(mapper.fileTime(forConcat: 7.5) == 7.5)
    }

    @Test
    func mapperWithSingleRegionShiftsByOffset() {
        let regions = [VoicedRegion(fileStart: 5.0, fileEnd: 12.0)]
        let mapper = VoicedTimeMapper(regions: regions, paddingBetween: 0)
        // concat 0 → file 5 (start of region)
        #expect(abs(mapper.fileTime(forConcat: 0.0) - 5.0) < 1e-9)
        // concat 3 → file 8
        #expect(abs(mapper.fileTime(forConcat: 3.0) - 8.0) < 1e-9)
        // concat 7 → file 12 (end)
        #expect(abs(mapper.fileTime(forConcat: 7.0) - 12.0) < 1e-9)
        // Beyond the region clamps to the last fileEnd.
        #expect(abs(mapper.fileTime(forConcat: 100.0) - 12.0) < 1e-9)
    }

    @Test
    func mapperWithMultipleRegionsAndPaddingMapsCorrectly() {
        // Region A: file 5–8 (3s),   Region B: file 16–19 (3s),   padding 0.3s
        // Concat layout:
        //   0.0 – 3.0   → file 5.0 – 8.0
        //   3.0 – 3.3   → padding (snaps to 8.0)
        //   3.3 – 6.3   → file 16.0 – 19.0
        let regions = [
            VoicedRegion(fileStart: 5.0, fileEnd: 8.0),
            VoicedRegion(fileStart: 16.0, fileEnd: 19.0),
        ]
        let mapper = VoicedTimeMapper(regions: regions, paddingBetween: 0.3)

        #expect(abs(mapper.fileTime(forConcat: 0.0) - 5.0) < 1e-9)
        #expect(abs(mapper.fileTime(forConcat: 1.5) - 6.5) < 1e-9)
        #expect(abs(mapper.fileTime(forConcat: 3.0) - 8.0) < 1e-9)
        // Inside the padding gap — snap to nearest boundary (end of A = 8.0)
        #expect(abs(mapper.fileTime(forConcat: 3.15) - 8.0) < 1e-9)
        #expect(abs(mapper.fileTime(forConcat: 3.3) - 16.0) < 1e-9)
        #expect(abs(mapper.fileTime(forConcat: 4.8) - 17.5) < 1e-9)
        #expect(abs(mapper.fileTime(forConcat: 6.3) - 19.0) < 1e-9)
        // Beyond the last region clamps.
        #expect(abs(mapper.fileTime(forConcat: 99.0) - 19.0) < 1e-9)
    }

    @Test
    func concatDurationAccountsForRegionsAndPadding() {
        let regions = [
            VoicedRegion(fileStart: 0, fileEnd: 2.0),
            VoicedRegion(fileStart: 10.0, fileEnd: 13.0),
            VoicedRegion(fileStart: 20.0, fileEnd: 21.0),
        ]
        let mapper = VoicedTimeMapper(regions: regions, paddingBetween: 0.5)
        // voiced total = 2 + 3 + 1 = 6, padding total = 2 * 0.5 = 1.0
        #expect(abs(mapper.concatDuration - 7.0) < 1e-9)
    }

    // MARK: - detectVoicedRegions

    private func makeTempDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("maycast-voiced-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Build a wav by concatenating segments. Each segment is either silence
    /// or a sine wave of the given duration. Returns the file URL.
    private func makeTestAudio(segments: [Segment], at url: URL, sampleRate: Double = 16000) throws {
        var combined: [Float] = []
        for seg in segments {
            switch seg {
            case .silence(let dur):
                let n = Int(dur * sampleRate)
                combined.append(contentsOf: repeatElement(0, count: n))
            case .sine(let dur, let amp):
                let n = Int(dur * sampleRate)
                for i in 0..<n {
                    let t = Double(i) / sampleRate
                    let s = Float(amp * sin(2 * .pi * 440 * t))
                    combined.append(s)
                }
            }
        }
        let buffer = AudioBuffer(sampleRate: sampleRate, channelCount: 1, samples: [combined])
        try AudioIO.writeWAV(buffer, to: url)
    }

    private enum Segment {
        case silence(Double)
        case sine(Double, amp: Double)
    }

    @Test
    func detectionOnAllSilenceReturnsNoRegions() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("silence.wav")
        try makeTestAudio(segments: [.silence(2.0)], at: url)

        let regions = try await Transcription.detectVoicedRegions(audioURL: url)
        #expect(regions.isEmpty)
    }

    @Test
    func detectionOnContinuousSineReturnsOneRegion() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("sine.wav")
        try makeTestAudio(segments: [.sine(2.0, amp: 0.3)], at: url)

        let regions = try await Transcription.detectVoicedRegions(audioURL: url)
        #expect(regions.count == 1)
        if let region = regions.first {
            // With 0.2s padding the region is roughly [-0.2, 2.2] clamped to [0, 2.0]
            #expect(region.fileStart < 0.05)
            #expect(region.fileEnd > 1.95)
        }
    }

    @Test
    func detectionFindsTwoRegionsSeparatedByLongSilence() async throws {
        // 1s silence | 1s sine | 2s silence (> minSilenceGap 0.6s) | 1s sine | 0.5s silence
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("two.wav")
        try makeTestAudio(segments: [
            .silence(1.0),
            .sine(1.0, amp: 0.3),
            .silence(2.0),
            .sine(1.0, amp: 0.3),
            .silence(0.5),
        ], at: url)

        let regions = try await Transcription.detectVoicedRegions(audioURL: url)
        #expect(regions.count == 2)
        guard regions.count == 2 else { return }
        // First region (raw 1.0–2.0, padded by 0.2 → 0.8–2.2)
        #expect(regions[0].fileStart > 0.7 && regions[0].fileStart < 0.95)
        #expect(regions[0].fileEnd > 2.05 && regions[0].fileEnd < 2.3)
        // Second region (raw 4.0–5.0, padded → 3.8–5.2)
        #expect(regions[1].fileStart > 3.7 && regions[1].fileStart < 3.95)
        #expect(regions[1].fileEnd > 5.05 && regions[1].fileEnd < 5.3)
    }

    @Test
    func detectionMergesAdjacentRegionsWithShortSilence() async throws {
        // Two sine bursts separated by 0.3s silence (< minSilenceGap 0.6) →
        // should be a single region.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("merged.wav")
        try makeTestAudio(segments: [
            .silence(0.5),
            .sine(0.5, amp: 0.3),
            .silence(0.3),
            .sine(0.5, amp: 0.3),
            .silence(0.5),
        ], at: url)

        let regions = try await Transcription.detectVoicedRegions(audioURL: url)
        #expect(regions.count == 1)
        if let region = regions.first {
            // Spans roughly the whole voiced portion (raw 0.5–1.8, padded a bit).
            #expect(region.fileStart < 0.55)
            #expect(region.fileEnd > 1.75)
        }
    }
}

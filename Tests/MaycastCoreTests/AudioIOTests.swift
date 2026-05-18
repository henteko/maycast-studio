import Testing
import Foundation
@testable import MaycastCore

@Suite("AudioIO")
struct AudioIOTests {
    private func makeTempDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("maycast-audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test
    func silenceHasExpectedFrameCount() {
        let buffer = AudioIO.silence(duration: 0.5, sampleRate: 48000, channelCount: 1)
        #expect(buffer.frameCount == 24000)
        #expect(abs(buffer.duration - 0.5) < 1e-6)
        #expect(buffer.samples[0].allSatisfy { $0 == 0 })
    }

    @Test
    func sineWaveHasExpectedRMS() {
        let buffer = AudioIO.sineWave(frequency: 440, duration: 1.0, amplitude: 0.5, sampleRate: 48000)
        #expect(buffer.frameCount == 48000)
        let rms = sqrt(buffer.samples[0].reduce(0) { $0 + Double($1 * $1) } / Double(buffer.frameCount))
        // RMS of a sine wave is amplitude / sqrt(2)
        #expect(abs(rms - 0.5 / sqrt(2.0)) < 0.01)
    }

    @Test
    func writeAndReadRoundTripPreservesAudio() throws {
        let workspace = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let original = AudioIO.sineWave(frequency: 440, duration: 0.25, sampleRate: 48000)
        let url = workspace.appendingPathComponent("sine.wav")
        try AudioIO.writeWAV(original, to: url)

        let roundTrip = try AudioIO.read(from: url)
        #expect(roundTrip.sampleRate == original.sampleRate)
        #expect(roundTrip.channelCount == original.channelCount)
        #expect(roundTrip.frameCount == original.frameCount)

        // Compare peaks (16-bit PCM quantization introduces tiny errors but peak should match within ~1/32768)
        let originalPeak = original.samples[0].map(abs).max() ?? 0
        let roundTripPeak = roundTrip.samples[0].map(abs).max() ?? 0
        #expect(abs(originalPeak - roundTripPeak) < 0.001)
    }

    @Test
    func concatProducesCorrectDuration() throws {
        let a = AudioIO.silence(duration: 0.5)
        let b = AudioIO.silence(duration: 0.3)
        let c = try AudioIO.concat([a, b])
        #expect(abs(c.duration - 0.8) < 1e-6)
        #expect(c.frameCount == a.frameCount + b.frameCount)
    }

    @Test
    func concatRejectsMismatchedFormat() {
        let a = AudioIO.silence(duration: 0.5, sampleRate: 48000)
        let b = AudioIO.silence(duration: 0.5, sampleRate: 44100)
        #expect(throws: MaycastError.self) {
            _ = try AudioIO.concat([a, b])
        }
    }

    @Test
    func renderClipPlacesSourceAtTimelineStart() {
        // Source: 4 seconds of sine wave (333 Hz → no zero-crossing at integer seconds)
        let source = AudioIO.sineWave(frequency: 333, duration: 4.0, amplitude: 0.5, sampleRate: 48000)
        // Arrangement: single clip taking source[2..4] placed at timelineStart=2
        // → Output 4s, silence 0-2s, sine 2-4s
        let clip = Clip(id: "x", sourceStart: 2.0, sourceEnd: 4.0, timelineStart: 2.0)
        let rendered = AudioIO.render(arrangement: Arrangement(clips: [clip]), from: source)

        #expect(abs(rendered.duration - 4.0) < 0.01)

        let sr = rendered.sampleRate
        let halfFrame = Int(2.0 * sr)

        // First half should be silent
        let silentRMS = sqrt(rendered.samples[0][0..<halfFrame]
            .reduce(0.0) { $0 + Double($1 * $1) } / Double(halfFrame))
        #expect(silentRMS < 1e-6)

        // Second half should have signal (RMS ~ amplitude/sqrt(2) for a sine)
        let audibleRMS = sqrt(rendered.samples[0][halfFrame..<rendered.frameCount]
            .reduce(0.0) { $0 + Double($1 * $1) } / Double(rendered.frameCount - halfFrame))
        #expect(audibleRMS > 0.3)
    }

    // MARK: - slice / readRange

    @Test
    func sliceCutsByTimeRange() {
        let buffer = AudioIO.sineWave(frequency: 440, duration: 2.0, amplitude: 0.5, sampleRate: 48000)
        let s = AudioIO.slice(buffer, from: 0.5, to: 1.5)
        #expect(abs(s.duration - 1.0) < 0.001)
        #expect(s.channelCount == buffer.channelCount)
    }

    @Test
    func sliceClampsToBufferBounds() {
        let buffer = AudioIO.sineWave(frequency: 440, duration: 1.0, amplitude: 0.5, sampleRate: 48000)
        let beyond = AudioIO.slice(buffer, from: 0.5, to: 10.0)
        #expect(abs(beyond.duration - 0.5) < 0.001)
        let inverted = AudioIO.slice(buffer, from: 0.9, to: 0.1)  // end < start → empty
        #expect(inverted.frameCount == 0)
    }

    @Test
    func readRangeReadsOnlyTheRequestedWindow() throws {
        let workspace = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let url = workspace.appendingPathComponent("two-segments.wav")
        // Build a 2s buffer with the first 1s at amplitude 0.1 and the second
        // 1s at amplitude 0.9 — read each half separately and check the RMS.
        let sr: Double = 48000
        let n = Int(sr)
        let quiet = [Float](repeating: 0.1, count: n)
        let loud = [Float](repeating: 0.9, count: n)
        try AudioIO.writeWAV(AudioBuffer(sampleRate: sr, channelCount: 1, samples: [quiet + loud]), to: url)

        let firstHalf = try AudioIO.readRange(from: url, startSec: 0, endSec: 1.0)
        let secondHalf = try AudioIO.readRange(from: url, startSec: 1.0, endSec: 2.0)
        #expect(abs(firstHalf.duration - 1.0) < 0.05)
        #expect(abs(secondHalf.duration - 1.0) < 0.05)
        let firstAvg = firstHalf.samples[0].reduce(0, +) / Float(firstHalf.frameCount)
        let secondAvg = secondHalf.samples[0].reduce(0, +) / Float(secondHalf.frameCount)
        #expect(abs(firstAvg - 0.1) < 0.02, "first-half mean was \(firstAvg)")
        #expect(abs(secondAvg - 0.9) < 0.02, "second-half mean was \(secondAvg)")
    }
}

import Testing
import Foundation
@testable import MaycastCore

@Suite("Loudness (ITU-R BS.1770-4)")
struct LoudnessTests {
    @Test
    func measuresFiniteLoudnessForSineWave() {
        let buffer = AudioIO.sineWave(frequency: 1000, duration: 2.0, amplitude: 0.5, sampleRate: 48000)
        let lufs = Loudness.integratedLUFS(buffer)
        #expect(lufs != nil)
        if let l = lufs {
            // A 1kHz sine at 0.5 amplitude has K-weighted loudness in a reasonable range.
            #expect(l > -30 && l < 0, "Unexpected LUFS: \(l)")
        }
    }

    @Test
    func silenceMeasuresAsNil() {
        let buffer = AudioIO.silence(duration: 2.0, sampleRate: 48000)
        let lufs = Loudness.integratedLUFS(buffer)
        #expect(lufs == nil)
    }

    @Test
    func normalizeReachesTargetWithinTolerance() {
        let buffer = AudioIO.sineWave(frequency: 333, duration: 2.0, amplitude: 0.3, sampleRate: 48000)
        let normalized = Loudness.normalize(buffer, toTargetLUFS: -18)
        let measured = Loudness.integratedLUFS(normalized)
        #expect(measured != nil)
        if let m = measured {
            #expect(abs(m - (-18)) < 0.5, "Expected LUFS ≈ -18, got \(m)")
        }
    }

    @Test
    func normalizeIsIdempotent() {
        let buffer = AudioIO.sineWave(frequency: 333, duration: 2.0, amplitude: 0.3, sampleRate: 48000)
        let once = Loudness.normalize(buffer, toTargetLUFS: -16)
        let twice = Loudness.normalize(once, toTargetLUFS: -16)
        let m1 = Loudness.integratedLUFS(once)!
        let m2 = Loudness.integratedLUFS(twice)!
        #expect(abs(m1 - m2) < 0.05)
    }

    @Test
    func unsupportedSampleRateReturnsNil() {
        let buffer = AudioIO.sineWave(frequency: 333, duration: 2.0, amplitude: 0.3, sampleRate: 44100)
        #expect(Loudness.integratedLUFS(buffer) == nil)
    }
}

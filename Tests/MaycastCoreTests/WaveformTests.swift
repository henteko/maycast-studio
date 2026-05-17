import Testing
import Foundation
@testable import MaycastCore

@Suite("Waveform")
struct WaveformTests {
    @Test
    func peaksMatchExpectedResolution() {
        let buffer = AudioIO.sineWave(frequency: 200, duration: 1.0, amplitude: 0.5, sampleRate: 48000)
        let peaks = WaveformGenerator.generate(buffer, peaksPerSecond: 100)
        #expect(peaks.peakCount == 100)
        #expect(abs(peaks.totalDuration - 1.0) < 0.01)
    }

    @Test
    func peaksReflectAmplitude() {
        let buffer = AudioIO.sineWave(frequency: 200, duration: 1.0, amplitude: 0.5, sampleRate: 48000)
        let peaks = WaveformGenerator.generate(buffer, peaksPerSecond: 100)
        let maxPeak = peaks.maxs.max() ?? 0
        let minPeak = peaks.mins.min() ?? 0
        #expect(maxPeak > 0.4 && maxPeak <= 0.5)
        #expect(minPeak < -0.4 && minPeak >= -0.5)
    }

    @Test
    func silenceProducesZeroPeaks() {
        let buffer = AudioIO.silence(duration: 1.0, sampleRate: 48000)
        let peaks = WaveformGenerator.generate(buffer, peaksPerSecond: 100)
        #expect(peaks.maxs.allSatisfy { $0 == 0 })
        #expect(peaks.mins.allSatisfy { $0 == 0 })
    }
}

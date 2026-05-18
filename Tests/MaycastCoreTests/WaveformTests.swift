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

    @Test
    func vdspPathMatchesNaiveScan() {
        // Random-ish stereo buffer — Accelerate's `vDSP_minv` / `vDSP_maxv`
        // must produce bit-identical peaks to a naïve Swift scan.
        let sr: Double = 48000
        let n = Int(0.5 * sr)
        var ch0 = [Float](repeating: 0, count: n)
        var ch1 = [Float](repeating: 0, count: n)
        var rng = SystemRandomNumberGenerator()
        for i in 0..<n {
            ch0[i] = Float(Double.random(in: -1...1, using: &rng))
            ch1[i] = Float(Double.random(in: -1...1, using: &rng))
        }
        let buffer = AudioBuffer(sampleRate: sr, channelCount: 2, samples: [ch0, ch1])
        let peaks = WaveformGenerator.generate(buffer, peaksPerSecond: 100)

        // Recompute peaks with the naïve scan and compare.
        let samplesPerPeak = max(1, Int(sr / 100))
        let peakCount = n / samplesPerPeak
        var refMin = [Float](repeating: 0, count: peakCount)
        var refMax = [Float](repeating: 0, count: peakCount)
        for p in 0..<peakCount {
            let start = p * samplesPerPeak
            let end = min(start + samplesPerPeak, n)
            var lo: Float = 0, hi: Float = 0
            for ch in [ch0, ch1] {
                for i in start..<end {
                    let s = ch[i]
                    if s < lo { lo = s }
                    if s > hi { hi = s }
                }
            }
            refMin[p] = lo
            refMax[p] = hi
        }
        #expect(peaks.mins == refMin)
        #expect(peaks.maxs == refMax)
    }
}

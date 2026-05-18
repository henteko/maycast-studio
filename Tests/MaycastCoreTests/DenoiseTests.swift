import Testing
import Foundation
@testable import MaycastCore

@Suite("Denoise (HPF + noise gate)")
struct DenoiseTests {
    /// Build a buffer by summing a list of generators. Each generator is a
    /// closure that fills the sample at time `t` (in seconds).
    private func makeBuffer(
        duration: Double,
        sampleRate: Double = 16000,
        channelCount: Int = 1,
        sample: (Double) -> Float
    ) -> AudioBuffer {
        let n = Int(duration * sampleRate)
        let channel = (0..<n).map { sample(Double($0) / sampleRate) }
        return AudioBuffer(
            sampleRate: sampleRate,
            channelCount: channelCount,
            samples: Array(repeating: channel, count: channelCount)
        )
    }

    private func rms(_ samples: ArraySlice<Float>) -> Double {
        let n = samples.count
        guard n > 0 else { return 0 }
        return sqrt(samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(n))
    }

    // MARK: - High-pass filter

    @Test
    func highPassAttenuatesLowFrequency() {
        // 40Hz sine — well below the 80Hz cutoff. Should be ≥ 6dB down.
        let buffer = makeBuffer(duration: 1.0) { t in
            Float(0.5 * sin(2 * .pi * 40 * t))
        }
        let filtered = Denoise.applyHighPass(buffer, cutoffHz: 80)
        // Trim transient at the start so we measure steady state.
        let trim = Int(0.1 * buffer.sampleRate)
        let originalRMS = rms(buffer.samples[0][trim...])
        let filteredRMS = rms(filtered.samples[0][trim...])
        #expect(filteredRMS < originalRMS * 0.5, "expected ≥ 6dB attenuation at 40Hz, got \(filteredRMS) vs \(originalRMS)")
    }

    @Test
    func highPassPreservesHighFrequency() {
        // 1kHz sine — well above the 80Hz cutoff. Should be nearly unchanged.
        let buffer = makeBuffer(duration: 1.0) { t in
            Float(0.5 * sin(2 * .pi * 1000 * t))
        }
        let filtered = Denoise.applyHighPass(buffer, cutoffHz: 80)
        let trim = Int(0.1 * buffer.sampleRate)
        let originalRMS = rms(buffer.samples[0][trim...])
        let filteredRMS = rms(filtered.samples[0][trim...])
        // Should retain at least 90% of the original RMS.
        #expect(filteredRMS > originalRMS * 0.9, "expected near-unity at 1kHz, got \(filteredRMS) vs \(originalRMS)")
    }

    // MARK: - Noise gate

    @Test
    func gateAttenuatesLowLevelSignal() {
        // -50dBFS signal → below default -45dBFS threshold → attenuated.
        let amp: Double = pow(10.0, -50.0 / 20.0)  // ~0.003
        let buffer = makeBuffer(duration: 1.0) { t in
            Float(amp * sin(2 * .pi * 1000 * t))
        }
        let gated = Denoise.applyNoiseGate(
            buffer,
            thresholdDB: -45, ratio: 4, attackMs: 5, releaseMs: 100
        )
        // After release time (~100ms) the gate should be fully closed.
        let measureStart = Int(0.5 * buffer.sampleRate)
        let originalRMS = rms(buffer.samples[0][measureStart...])
        let gatedRMS = rms(gated.samples[0][measureStart...])
        #expect(gatedRMS < originalRMS * 0.5, "expected ≥ 6dB attenuation below threshold, got \(gatedRMS) vs \(originalRMS)")
    }

    @Test
    func gatePreservesAboveThresholdSignal() {
        // -10dBFS signal → well above threshold → almost no attenuation.
        let amp: Double = pow(10.0, -10.0 / 20.0)  // ~0.316
        let buffer = makeBuffer(duration: 1.0) { t in
            Float(amp * sin(2 * .pi * 1000 * t))
        }
        let gated = Denoise.applyNoiseGate(
            buffer,
            thresholdDB: -45, ratio: 4, attackMs: 5, releaseMs: 100
        )
        let measureStart = Int(0.5 * buffer.sampleRate)
        let originalRMS = rms(buffer.samples[0][measureStart...])
        let gatedRMS = rms(gated.samples[0][measureStart...])
        // Allow 5% tolerance for tiny envelope smoothing effects.
        #expect(gatedRMS > originalRMS * 0.95, "expected near-unity above threshold, got \(gatedRMS) vs \(originalRMS)")
    }

    // MARK: - Full pipeline

    @Test
    func processReducesNoiseInQuietSegments() {
        // Build: 0.5s of -55dBFS noise + 0.5s of -10dBFS tone.
        // After denoise the noise floor should be much lower; the tone should
        // be preserved.
        let sr: Double = 16000
        let n = Int(1.0 * sr)
        let half = n / 2
        var samples = [Float](repeating: 0, count: n)
        let noiseAmp: Double = pow(10.0, -55.0 / 20.0)  // ~0.0018
        let toneAmp: Double = pow(10.0, -10.0 / 20.0)
        var rng = SystemRandomNumberGenerator()
        for i in 0..<half {
            let r = Double.random(in: -1...1, using: &rng)
            samples[i] = Float(noiseAmp * r)
        }
        for i in half..<n {
            let t = Double(i) / sr
            samples[i] = Float(toneAmp * sin(2 * .pi * 1000 * t))
        }
        let buffer = AudioBuffer(sampleRate: sr, channelCount: 1, samples: [samples])

        let denoised = Denoise.process(buffer)

        // Quiet segment: measure from 0.1s to 0.4s (skip startup transients).
        let quietRMS_before = rms(buffer.samples[0][Int(0.1 * sr)..<Int(0.4 * sr)])
        let quietRMS_after = rms(denoised.samples[0][Int(0.1 * sr)..<Int(0.4 * sr)])
        #expect(quietRMS_after < quietRMS_before * 0.5)

        // Loud segment: measure from 0.7s onward (after gate opens).
        let loudRMS_before = rms(buffer.samples[0][Int(0.7 * sr)..<n])
        let loudRMS_after = rms(denoised.samples[0][Int(0.7 * sr)..<n])
        #expect(loudRMS_after > loudRMS_before * 0.9)
    }

    @Test
    func processIsStableOnAllSilence() {
        let buffer = AudioBuffer(
            sampleRate: 16000, channelCount: 1,
            samples: [[Float](repeating: 0, count: 16000)]
        )
        let denoised = Denoise.process(buffer)
        // Should not produce NaNs or huge values.
        #expect(denoised.samples[0].allSatisfy { $0.isFinite && abs($0) < 0.01 })
    }

    @Test
    func processPreservesStereoChannels() {
        let sr: Double = 16000
        let n = Int(1.0 * sr)
        let amp: Double = pow(10.0, -10.0 / 20.0)
        let chL = (0..<n).map { Float(amp * sin(2 * .pi * 1000 * Double($0) / sr)) }
        let chR = (0..<n).map { Float(amp * sin(2 * .pi * 500 * Double($0) / sr)) }
        let buffer = AudioBuffer(sampleRate: sr, channelCount: 2, samples: [chL, chR])
        let denoised = Denoise.process(buffer)
        #expect(denoised.channelCount == 2)
        #expect(denoised.samples[0].count == n)
        #expect(denoised.samples[1].count == n)
    }
}

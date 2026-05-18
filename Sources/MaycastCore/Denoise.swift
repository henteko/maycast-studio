import Foundation

/// Time-domain denoise pipeline used by Polish (Phase 3.2).
///
/// Two stages, both stateless DSP per-channel:
///
/// 1. **High-pass filter** (Butterworth, 2nd order, default 80 Hz) — removes
///    HVAC rumble and low-frequency room noise. Cutoff is below the lowest
///    vocal fundamentals (~85 Hz for adult male) so voice is preserved.
///
/// 2. **Downward expander** (a "soft" noise gate) — attenuates audio whose
///    envelope falls below `threshold`. Above threshold the signal passes
///    unchanged; below it, gain follows a smooth curve so the transition
///    isn't audible as chattering. This kills hiss and low-level steady
///    noise between phrases without introducing spectral artefacts.
///
/// We deliberately avoid spectral subtraction because of "musical noise"
/// artefacts that are easy to introduce and hard to suppress without making
/// the algorithm much more complex.
public enum Denoise {
    /// Apply the full denoise pipeline with conservative defaults tuned for
    /// spoken-word recordings.
    public static func process(
        _ buffer: AudioBuffer,
        highPassHz: Double = 80,
        gateThresholdDB: Double = -45,
        gateRatio: Double = 4,
        gateAttackMs: Double = 5,
        gateReleaseMs: Double = 100
    ) -> AudioBuffer {
        let hp = applyHighPass(buffer, cutoffHz: highPassHz)
        return applyNoiseGate(
            hp,
            thresholdDB: gateThresholdDB,
            ratio: gateRatio,
            attackMs: gateAttackMs,
            releaseMs: gateReleaseMs
        )
    }

    // MARK: - High-pass filter (Butterworth biquad, direct form I)

    public static func applyHighPass(_ buffer: AudioBuffer, cutoffHz: Double) -> AudioBuffer {
        let sr = buffer.sampleRate
        guard sr > 0, cutoffHz > 0, cutoffHz < sr / 2 else { return buffer }

        let omega = 2.0 * Double.pi * cutoffHz / sr
        let cos_o = cos(omega)
        let sin_o = sin(omega)
        let Q = 1.0 / sqrt(2.0)  // Butterworth
        let alpha = sin_o / (2.0 * Q)

        // RBJ Audio EQ Cookbook: high-pass
        let b0 = (1.0 + cos_o) / 2.0
        let b1 = -(1.0 + cos_o)
        let b2 = (1.0 + cos_o) / 2.0
        let a0 = 1.0 + alpha
        let a1 = -2.0 * cos_o
        let a2 = 1.0 - alpha

        let nb0 = b0 / a0, nb1 = b1 / a0, nb2 = b2 / a0
        let na1 = a1 / a0, na2 = a2 / a0

        var outChannels: [[Float]] = []
        outChannels.reserveCapacity(buffer.channelCount)
        for ch in 0..<buffer.channelCount {
            var x1: Double = 0, x2: Double = 0
            var y1: Double = 0, y2: Double = 0
            var out = [Float](repeating: 0, count: buffer.frameCount)
            for i in 0..<buffer.frameCount {
                let x = Double(buffer.samples[ch][i])
                let y = nb0 * x + nb1 * x1 + nb2 * x2 - na1 * y1 - na2 * y2
                x2 = x1; x1 = x
                y2 = y1; y1 = y
                out[i] = Float(y)
            }
            outChannels.append(out)
        }
        return AudioBuffer(sampleRate: sr, channelCount: buffer.channelCount, samples: outChannels)
    }

    // MARK: - Noise gate / downward expander

    /// One-pole envelope follower + soft downward expander.
    public static func applyNoiseGate(
        _ buffer: AudioBuffer,
        thresholdDB: Double,
        ratio: Double,
        attackMs: Double,
        releaseMs: Double
    ) -> AudioBuffer {
        let sr = buffer.sampleRate
        guard sr > 0 else { return buffer }
        let threshold = pow(10.0, thresholdDB / 20.0)
        let attackSamples = max(1.0, attackMs * sr / 1000.0)
        let releaseSamples = max(1.0, releaseMs * sr / 1000.0)
        let envSamples = max(1.0, 5.0 * sr / 1000.0)  // 5ms envelope smoothing

        let attackCoeff = exp(-1.0 / attackSamples)
        let releaseCoeff = exp(-1.0 / releaseSamples)
        let envCoeff = exp(-1.0 / envSamples)

        var outChannels: [[Float]] = []
        outChannels.reserveCapacity(buffer.channelCount)
        for ch in 0..<buffer.channelCount {
            var envelope: Double = 0
            var gain: Double = 1.0
            var out = [Float](repeating: 0, count: buffer.frameCount)
            for i in 0..<buffer.frameCount {
                let x = Double(buffer.samples[ch][i])

                // Peak envelope follower: instant attack, exponential release.
                let rectified = abs(x)
                if rectified > envelope {
                    envelope = rectified
                } else {
                    envelope = rectified + (envelope - rectified) * envCoeff
                }

                // Soft expander curve.
                let targetGain: Double
                if envelope >= threshold {
                    targetGain = 1.0
                } else if envelope <= 0 {
                    targetGain = 0
                } else {
                    // (envelope / threshold)^(ratio - 1) — 1.0 at threshold,
                    // tends to 0 as the envelope drops. With ratio=4 a 6dB
                    // drop below threshold produces ~18dB of attenuation.
                    targetGain = pow(envelope / threshold, ratio - 1.0)
                }

                // Smooth the gain. Opening = attack; closing = release.
                if targetGain > gain {
                    gain = targetGain + (gain - targetGain) * attackCoeff
                } else {
                    gain = targetGain + (gain - targetGain) * releaseCoeff
                }

                out[i] = Float(x * gain)
            }
            outChannels.append(out)
        }
        return AudioBuffer(sampleRate: sr, channelCount: buffer.channelCount, samples: outChannels)
    }
}

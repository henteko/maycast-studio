import Foundation

/// ITU-R BS.1770-4 integrated loudness measurement.
///
/// Coefficients for the K-weighting biquads are the standard 48 kHz values;
/// other sample rates would need recomputed coefficients.
///
/// Loudness *normalisation* used to live here too, but has moved out of the
/// app: the Polish flow is now a thin shim around the Auphonic API, which
/// performs its own gain staging. This module is kept solely so the editor
/// UI can display "before" LUFS values per track.
public enum Loudness {
    private static let absoluteThresholdLUFS: Double = -70.0
    private static let blockDurationSec: Double = 0.4
    private static let blockHopSec: Double = 0.1

    /// Measure integrated loudness in LUFS for the given buffer.
    /// Returns `nil` if no gated blocks are above the absolute threshold
    /// (effectively silent input) or the sample rate is unsupported.
    public static func integratedLUFS(_ buffer: AudioBuffer) -> Double? {
        guard buffer.sampleRate == 48000 else { return nil }
        let sr = buffer.sampleRate
        let blockSize = Int(blockDurationSec * sr)
        let hopSize = Int(blockHopSec * sr)
        guard buffer.frameCount >= blockSize else { return nil }

        let filtered = applyKWeighting(buffer)
        let blockLoudnessLUFS = blockLoudness(filtered: filtered, blockSize: blockSize, hopSize: hopSize)

        // Gate 1: absolute threshold (-70 LUFS)
        let gated1 = blockLoudnessLUFS.filter { $0 > absoluteThresholdLUFS }
        guard !gated1.isEmpty else { return nil }

        // Relative threshold = gated mean - 10 LU
        let meanEnergy1 = gated1.map { lufsToEnergy($0) }.reduce(0, +) / Double(gated1.count)
        let relThreshold = energyToLUFS(meanEnergy1) - 10.0

        let gated2 = gated1.filter { $0 > relThreshold }
        guard !gated2.isEmpty else { return nil }

        let meanEnergy2 = gated2.map { lufsToEnergy($0) }.reduce(0, +) / Double(gated2.count)
        return energyToLUFS(meanEnergy2)
    }

    // MARK: - Internals

    private static func lufsToEnergy(_ lufs: Double) -> Double {
        pow(10.0, (lufs + 0.691) / 10.0)
    }

    private static func energyToLUFS(_ energy: Double) -> Double {
        -0.691 + 10.0 * log10(max(energy, .leastNormalMagnitude))
    }

    private static func blockLoudness(filtered: AudioBuffer, blockSize: Int, hopSize: Int) -> [Double] {
        var result: [Double] = []
        var start = 0
        while start + blockSize <= filtered.frameCount {
            var energy: Double = 0
            for ch in 0..<filtered.channelCount {
                var ch_sum: Double = 0
                let channelSamples = filtered.samples[ch]
                for i in start..<(start + blockSize) {
                    let s = Double(channelSamples[i])
                    ch_sum += s * s
                }
                // ITU-R BS.1770 channel weights: L/R/C = 1.0, surround = 1.41.
                // For mono and stereo (the cases we expose) all channels are weight 1.
                let weight = 1.0
                energy += weight * (ch_sum / Double(blockSize))
            }
            if energy > 0 {
                result.append(energyToLUFS(energy))
            }
            start += hopSize
        }
        return result
    }

    // MARK: - K-weighting filters (48 kHz coefficients per BS.1770-4)

    private struct BiquadCoefs {
        let b0, b1, b2, a1, a2: Double
    }

    private static let preFilter = BiquadCoefs(
        b0:  1.53512485958697,
        b1: -2.69169618940638,
        b2:  1.19839281085285,
        a1: -1.69065929318241,
        a2:  0.73248077421585
    )

    private static let rlbFilter = BiquadCoefs(
        b0:  1.0,
        b1: -2.0,
        b2:  1.0,
        a1: -1.99004745483398,
        a2:  0.99007225036621
    )

    private static func applyKWeighting(_ buffer: AudioBuffer) -> AudioBuffer {
        var filtered: [[Float]] = []
        filtered.reserveCapacity(buffer.channelCount)
        for ch in 0..<buffer.channelCount {
            var samples = buffer.samples[ch]
            biquadInPlace(&samples, coefs: preFilter)
            biquadInPlace(&samples, coefs: rlbFilter)
            filtered.append(samples)
        }
        return AudioBuffer(
            sampleRate: buffer.sampleRate,
            channelCount: buffer.channelCount,
            samples: filtered
        )
    }

    private static func biquadInPlace(_ samples: inout [Float], coefs: BiquadCoefs) {
        var x1: Double = 0
        var x2: Double = 0
        var y1: Double = 0
        var y2: Double = 0
        for i in 0..<samples.count {
            let x = Double(samples[i])
            let y = coefs.b0 * x
                  + coefs.b1 * x1
                  + coefs.b2 * x2
                  - coefs.a1 * y1
                  - coefs.a2 * y2
            x2 = x1
            x1 = x
            y2 = y1
            y1 = y
            samples[i] = Float(y)
        }
    }
}

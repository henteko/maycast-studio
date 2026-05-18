import Testing
import Foundation
@testable import MaycastCore

@Suite("AudioIO.composeFinalMix")
struct MixComposeTests {
    private let sr: Double = 48000

    private func makeMono(duration: Double, amplitude: Float = 0.5, sampleRate: Double? = nil) -> AudioBuffer {
        let s = sampleRate ?? sr
        let n = Int(duration * s)
        return AudioBuffer(
            sampleRate: s,
            channelCount: 1,
            samples: [[Float](repeating: amplitude, count: n)]
        )
    }

    private func makeStereo(duration: Double, amplitude: Float = 0.5) -> AudioBuffer {
        let n = Int(duration * sr)
        return AudioBuffer(
            sampleRate: sr, channelCount: 2,
            samples: [
                [Float](repeating: amplitude, count: n),
                [Float](repeating: amplitude, count: n),
            ]
        )
    }

    // MARK: - Basic timeline math

    @Test
    func noIntroNoOutroReturnsVoiceUnchanged() throws {
        let voice = makeStereo(duration: 2.0, amplitude: 0.4)
        let out = try AudioIO.composeFinalMix(voiceMaster: voice, intro: nil, outro: nil)
        #expect(abs(out.duration - 2.0) < 1e-3)
        // Output is stereo, same amplitude (no ducking applied).
        #expect(out.channelCount == 2)
        #expect(abs(out.samples[0][sr10ms()] - 0.4) < 1e-5)
    }

    @Test
    func introExtendsDurationByIntroDurMinusOffset() throws {
        // voice = 5s, intro = 3s, introOffset = 1s → total = 3 + (5 - 1) = 7s
        let voice = makeStereo(duration: 5.0, amplitude: 0.3)
        let intro = makeMono(duration: 3.0, amplitude: 0.3)
        let out = try AudioIO.composeFinalMix(
            voiceMaster: voice,
            intro: intro,
            outro: nil,
            introOffsetSec: 1.0
        )
        #expect(abs(out.duration - 7.0) < 0.01)
    }

    @Test
    func outroExtendsDurationByOutroDurMinusOffset() throws {
        // voice = 4s, outro = 3s, outroOffset = 1s → total = 4 + (3 - 1) = 6s
        let voice = makeStereo(duration: 4.0, amplitude: 0.3)
        let outro = makeMono(duration: 3.0, amplitude: 0.3)
        let out = try AudioIO.composeFinalMix(
            voiceMaster: voice,
            intro: nil,
            outro: outro,
            outroOffsetSec: 1.0
        )
        #expect(abs(out.duration - 6.0) < 0.01)
    }

    @Test
    func bothIntroAndOutroAddsBoth() throws {
        // voice 5s + intro 3s/offset 1s + outro 3s/offset 1s → 3 + (5-1) + (3-1) = 9
        let voice = makeStereo(duration: 5.0, amplitude: 0.3)
        let intro = makeMono(duration: 3.0, amplitude: 0.3)
        let outro = makeMono(duration: 3.0, amplitude: 0.3)
        let out = try AudioIO.composeFinalMix(
            voiceMaster: voice,
            intro: intro, outro: outro,
            introOffsetSec: 1.0, outroOffsetSec: 1.0
        )
        #expect(abs(out.duration - 9.0) < 0.01)
    }

    // MARK: - Ducking

    @Test
    func introIsDuckedDuringOverlap() throws {
        // Use no fade so the transition is a clean step at duckStart.
        // intro 2s @ 1.0, voice 2s @ 0 (silent so we measure intro contribution alone).
        let intro = makeMono(duration: 2.0, amplitude: 1.0)
        let voice = makeStereo(duration: 2.0, amplitude: 0)
        let out = try AudioIO.composeFinalMix(
            voiceMaster: voice,
            intro: intro,
            outro: nil,
            introOffsetSec: 1.0,
            duckingGainDB: -12,
            duckingFadeSec: 0
        )
        // Master starts at t = introDur - introOffset = 1.0.
        // - Before 1.0: intro at full = 1.0
        // - After 1.0 (within intro): intro ducked to ~0.251 (-12 dB)
        let duckAmp = Double(pow(10.0, -12.0 / 20.0))
        let preDuck = out.samples[0][Int(0.5 * sr)]  // 0.5s in
        let postDuck = out.samples[0][Int(1.5 * sr)]  // 1.5s in
        #expect(abs(Double(preDuck) - 1.0) < 0.01, "expected full intro before duck, got \(preDuck)")
        #expect(abs(Double(postDuck) - duckAmp) < 0.01, "expected ducked intro after duck, got \(postDuck)")
    }

    @Test
    func outroIsDuckedDuringOverlapAndFullAfter() throws {
        // voice 2s silent, outro 2s @ 1.0, outroOffset 1s, no fade.
        // outroStart = voiceDur - outroOffset = 1.0
        // - 0..1.0: no outro (just silent voice)
        // - 1.0..2.0: outro within overlap → ducked
        // - 2.0..3.0: outro after overlap → full (1.0)
        let voice = makeStereo(duration: 2.0, amplitude: 0)
        let outro = makeMono(duration: 2.0, amplitude: 1.0)
        let out = try AudioIO.composeFinalMix(
            voiceMaster: voice,
            intro: nil,
            outro: outro,
            outroOffsetSec: 1.0,
            duckingGainDB: -12,
            duckingFadeSec: 0
        )
        let duckAmp = Double(pow(10.0, -12.0 / 20.0))
        let inOverlap = out.samples[0][Int(1.5 * sr)]
        let afterOverlap = out.samples[0][Int(2.5 * sr)]
        #expect(abs(Double(inOverlap) - duckAmp) < 0.01, "expected ducked outro, got \(inOverlap)")
        #expect(abs(Double(afterOverlap) - 1.0) < 0.01, "expected full outro after overlap, got \(afterOverlap)")
    }

    @Test
    func voicePlaysAtFullVolumeAcrossOverlap() throws {
        // intro 2s @ 0 (silent), voice 2s @ 0.5. With offset, the voice should
        // appear at full level after `introDur - introOffset` regardless of
        // ducking parameters.
        let intro = makeMono(duration: 2.0, amplitude: 0)
        let voice = makeStereo(duration: 2.0, amplitude: 0.5)
        let out = try AudioIO.composeFinalMix(
            voiceMaster: voice,
            intro: intro, outro: nil,
            introOffsetSec: 1.0,
            duckingFadeSec: 0
        )
        // voice starts at t = 1.0
        let vMid = out.samples[0][Int(2.0 * sr)]  // 1s into voice
        #expect(abs(Double(vMid) - 0.5) < 0.01)
    }

    // MARK: - Sample-rate handling

    @Test
    func resamplesMismatchedSampleRatesAutomatically() throws {
        // Voice at 48 kHz, intro at 44.1 kHz — composeFinalMix should
        // resample the intro to match before stitching the timeline.
        let voice = makeStereo(duration: 2.0, amplitude: 0.3)
        let intro = makeMono(duration: 2.0, amplitude: 0.3, sampleRate: 44100)
        let out = try AudioIO.composeFinalMix(
            voiceMaster: voice,
            intro: intro,
            outro: nil,
            introOffsetSec: 1.0
        )
        // intro (resampled, 2s) + voice 2s - introOffset 1s = 3s. Output is
        // at the voice master's 48 kHz.
        #expect(abs(out.duration - 3.0) < 0.02)
        #expect(out.sampleRate == 48000)
    }

    private func sr10ms() -> Int { Int(0.010 * sr) }
}

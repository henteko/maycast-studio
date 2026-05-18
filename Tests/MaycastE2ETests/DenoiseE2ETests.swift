import Testing
import Foundation
import MaycastCore

@Suite("polish --denoise")
struct DenoiseE2ETests {
    /// Write a wav whose first half is low-amplitude noise (-55 dBFS) and
    /// second half is a -10 dBFS tone. Used to verify the gate kills the
    /// noise floor while preserving real content.
    private func writeNoisyToneWAV(at url: URL, sampleRate: Double = 16000) throws {
        let n = Int(1.0 * sampleRate)
        let half = n / 2
        var samples = [Float](repeating: 0, count: n)
        let noiseAmp = Float(pow(10.0, -55.0 / 20.0))
        let toneAmp = pow(10.0, -10.0 / 20.0)
        var rng = SystemRandomNumberGenerator()
        for i in 0..<half {
            samples[i] = noiseAmp * Float(Double.random(in: -1...1, using: &rng))
        }
        for i in half..<n {
            let t = Double(i) / sampleRate
            samples[i] = Float(toneAmp * sin(2 * .pi * 1000 * t))
        }
        let buf = AudioBuffer(sampleRate: sampleRate, channelCount: 1, samples: [samples])
        try AudioIO.writeWAV(buf, to: url)
    }

    private func rms(_ samples: ArraySlice<Float>) -> Double {
        let n = samples.count
        guard n > 0 else { return 0 }
        return sqrt(samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(n))
    }

    @Test
    func denoiseAttenuatesQuietRegionsAndKeepsTone() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }

        let episodePath = workspace.appendingPathComponent("ep01.maycast")
        _ = try harness.run(["init", episodePath.path])

        let host = workspace.appendingPathComponent("host.wav")
        try writeNoisyToneWAV(at: host)
        _ = try harness.run(["import", "-project", episodePath.path, "--as", "host", host.path])

        let result = try harness.run([
            "polish", "-project", episodePath.path, "--track", "host", "--denoise",
        ])
        #expect(result.succeeded, "stderr: \(result.stderr)")

        let outURL = episodePath.appendingPathComponent("intermediate/host/002_polish.wav")
        let before = try AudioIO.read(from: host)
        let after = try AudioIO.read(from: outURL)
        let sr = before.sampleRate

        // Quiet region (0.1s – 0.4s): denoised version should be much quieter.
        let quietBefore = rms(before.samples[0][Int(0.1 * sr)..<Int(0.4 * sr)])
        let quietAfter  = rms(after.samples[0][Int(0.1 * sr)..<Int(0.4 * sr)])
        #expect(quietAfter < quietBefore * 0.5,
                "expected ≥6dB attenuation in noise region, got \(quietAfter) vs \(quietBefore)")

        // Loud region (0.7s onward): tone preserved within ~10% RMS.
        let loudBefore = rms(before.samples[0][Int(0.7 * sr)..<before.frameCount])
        let loudAfter  = rms(after.samples[0][Int(0.7 * sr)..<after.frameCount])
        #expect(loudAfter > loudBefore * 0.85,
                "expected tone preserved, got \(loudAfter) vs \(loudBefore)")
    }

    @Test
    func paramsRecordIncludesDenoiseFlag() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }

        let episodePath = workspace.appendingPathComponent("ep01.maycast")
        _ = try harness.run(["init", episodePath.path])
        let host = workspace.appendingPathComponent("host.wav")
        try harness.writeSilentWAV(at: host, duration: 0.5)
        _ = try harness.run(["import", "-project", episodePath.path, "--as", "host", host.path])

        let result = try harness.run([
            "polish", "-project", episodePath.path, "--track", "host", "--denoise",
        ])
        #expect(result.succeeded, "stderr: \(result.stderr)")

        let paramsURL = episodePath.appendingPathComponent("intermediate/host/002_polish.params.json")
        let data = try Data(contentsOf: paramsURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let params = json?["params"] as? [String: Any]
        #expect(params?["denoise"] as? Bool == true)
    }
}

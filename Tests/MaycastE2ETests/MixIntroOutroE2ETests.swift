import Testing
import Foundation
import MaycastCore

@Suite("maycast mix (intro / outro)")
struct MixIntroOutroE2ETests {
    private func writeTone(at url: URL, duration: Double, freq: Double = 440) throws {
        let buf = AudioIO.sineWave(frequency: freq, duration: duration, amplitude: 0.3, sampleRate: 48000)
        try AudioIO.writeWAV(buf, to: url)
    }

    @Test
    func plainMixDurationMatchesLongestTrack() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }

        let episode = workspace.appendingPathComponent("ep01.maycast")
        _ = try harness.run(["init", episode.path])
        let host = workspace.appendingPathComponent("host.wav")
        try writeTone(at: host, duration: 3.0)
        _ = try harness.run(["import", "-project", episode.path, "--as", "host", host.path])

        let result = try harness.run(["mix", "-project", episode.path])
        #expect(result.succeeded, "stderr: \(result.stderr)")
        let exported = try AudioIO.read(from: episode.appendingPathComponent("exports/ep01.wav"))
        #expect(abs(exported.duration - 3.0) < 0.05)
    }

    @Test
    func mixWithIntroExtendsDurationByIntroMinusOffset() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }

        let episode = workspace.appendingPathComponent("ep01.maycast")
        _ = try harness.run(["init", episode.path])

        // Plant a 2s intro inside the episode's assets/ directory and point
        // MixConfig at it (mirroring what `init` with a `--show` does).
        let assetsDir = episode.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        let introURL = assetsDir.appendingPathComponent("intro.wav")
        try writeTone(at: introURL, duration: 2.0, freq: 220)

        // Hand-edit episode.json to attach the intro (no CLI for this yet).
        let manifestURL = episode.appendingPathComponent("episode.json")
        var manifestObj = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
        manifestObj["mix"] = [
            "intro": "assets/intro.wav",
            "introOffsetSec": 0.5,
            "outroOffsetSec": 5.0,
            "duckingGainDB": -12,
            "duckingFadeSec": 0.5,
        ] as [String: Any]
        let updated = try JSONSerialization.data(withJSONObject: manifestObj, options: [.prettyPrinted])
        try updated.write(to: manifestURL)

        let host = workspace.appendingPathComponent("host.wav")
        try writeTone(at: host, duration: 3.0)
        _ = try harness.run(["import", "-project", episode.path, "--as", "host", host.path])

        let result = try harness.run([
            "mix", "-project", episode.path,
        ])
        #expect(result.succeeded, "stderr: \(result.stderr)")
        let exported = try AudioIO.read(from: episode.appendingPathComponent("exports/ep01.wav"))
        // intro 2s + voice 3s - introOffset 0.5s = 4.5s
        #expect(abs(exported.duration - 4.5) < 0.05, "got \(exported.duration)s")
    }

    @Test
    func cliFlagsOverrideMixConfig() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }

        let episode = workspace.appendingPathComponent("ep01.maycast")
        _ = try harness.run(["init", episode.path])
        let assetsDir = episode.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        try writeTone(at: assetsDir.appendingPathComponent("intro.wav"), duration: 2.0, freq: 220)

        let manifestURL = episode.appendingPathComponent("episode.json")
        var manifestObj = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
        manifestObj["mix"] = [
            "intro": "assets/intro.wav",
            "introOffsetSec": 2.0,  // default, but override below
        ] as [String: Any]
        let updated = try JSONSerialization.data(withJSONObject: manifestObj, options: [.prettyPrinted])
        try updated.write(to: manifestURL)

        let host = workspace.appendingPathComponent("host.wav")
        try writeTone(at: host, duration: 3.0)
        _ = try harness.run(["import", "-project", episode.path, "--as", "host", host.path])

        // Override intro-offset to 0 → no overlap → total = 2 + 3 = 5s.
        let result = try harness.run([
            "mix", "-project", episode.path,
            "--intro-offset", "0",
        ])
        #expect(result.succeeded, "stderr: \(result.stderr)")
        let exported = try AudioIO.read(from: episode.appendingPathComponent("exports/ep01.wav"))
        #expect(abs(exported.duration - 5.0) < 0.05, "got \(exported.duration)s")
    }
}

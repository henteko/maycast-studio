import Testing
import Foundation
import MaycastCore

@Suite("mix (parallel sum)")
struct MixE2ETests {
    private func setupTwoTrackEpisode(
        harness: E2EHarness,
        workspace: URL,
        hostDuration: Double,
        guestDuration: Double
    ) throws -> URL {
        let episode = workspace.appendingPathComponent("ep01.maycast")
        _ = try harness.run(["init", episode.path])

        let host = workspace.appendingPathComponent("host.wav")
        let guest = workspace.appendingPathComponent("guest.wav")
        try harness.writeSineWaveWAV(at: host, frequency: 333, duration: hostDuration)
        try harness.writeSineWaveWAV(at: guest, frequency: 555, duration: guestDuration)
        _ = try harness.run(["import", "-project", episode.path, "--as", "host",  host.path])
        _ = try harness.run(["import", "-project", episode.path, "--as", "guest", guest.path])
        return episode
    }

    @Test
    func mixOutputIsStereoWithMaxDuration() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }
        let episode = try setupTwoTrackEpisode(
            harness: harness, workspace: workspace,
            hostDuration: 2.0, guestDuration: 3.0
        )

        let result = try harness.run([
            "mix", "-project", episode.path, "--output", "exports/ep01.m4a",
        ])
        #expect(result.succeeded, "stderr: \(result.stderr)")

        let outputURL = episode.appendingPathComponent("exports/ep01.m4a")
        let buffer = try AudioIO.read(from: outputURL)
        #expect(buffer.channelCount == 2)
        #expect(abs(buffer.duration - 3.0) < 0.05, "expected duration max(2, 3) = 3, got \(buffer.duration)")
    }

    @Test
    func mixSumsSignalFromBothTracks() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }
        let episode = try setupTwoTrackEpisode(
            harness: harness, workspace: workspace,
            hostDuration: 2.0, guestDuration: 2.0
        )

        _ = try harness.run(["mix", "-project", episode.path, "--output", "exports/ep01.m4a"])
        let buffer = try AudioIO.read(from: episode.appendingPathComponent("exports/ep01.m4a"))

        // Each input is a 0.5-amplitude sine wave (RMS ≈ 0.354). Summing two
        // independent sine waves produces RMS ≈ sqrt(0.354^2 + 0.354^2) ≈ 0.5.
        // We're lenient and just check RMS > one input's RMS.
        let leftRMS = sqrt(buffer.samples[0].reduce(0.0) { $0 + Double($1 * $1) } / Double(buffer.frameCount))
        #expect(leftRMS > 0.4, "expected mixed RMS to exceed single-track RMS, got \(leftRMS)")
    }

    @Test
    func mixHandlesTracksWithDifferentSampleRates() throws {
        // Polish output may preserve each source track's native sample rate, so
        // two voice tracks in the same episode can end up at different SRs
        // (e.g. 48 kHz vs 44.1 kHz). mix must transparently resample them to a
        // common rate instead of failing with "Audio format mismatch".
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }
        let episode = workspace.appendingPathComponent("ep01.maycast")
        _ = try harness.run(["init", episode.path])

        let host = workspace.appendingPathComponent("host.wav")
        let guest = workspace.appendingPathComponent("guest.wav")
        try harness.writeSineWaveWAV(at: host, frequency: 333, duration: 2.0, sampleRate: 48000)
        try harness.writeSineWaveWAV(at: guest, frequency: 555, duration: 2.0, sampleRate: 44100)
        _ = try harness.run(["import", "-project", episode.path, "--as", "host",  host.path])
        _ = try harness.run(["import", "-project", episode.path, "--as", "guest", guest.path])

        let result = try harness.run([
            "mix", "-project", episode.path, "--output", "exports/ep01.m4a",
        ])
        #expect(result.succeeded, "stderr: \(result.stderr)")
        let buffer = try AudioIO.read(from: episode.appendingPathComponent("exports/ep01.m4a"))
        #expect(buffer.channelCount == 2)
        #expect(abs(buffer.duration - 2.0) < 0.05, "expected ~2.0s, got \(buffer.duration)")
    }

    @Test
    func mixHandlesOutroSampleRateMismatch() throws {
        // The intro / outro asset usually comes from the Show (e.g. an MP3 at
        // 44.1 kHz) while voice tracks are recorded / polished at 48 kHz. mix
        // must auto-resample the outro to match the voice master rather than
        // refusing with "Audio format mismatch".
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }
        let episode = workspace.appendingPathComponent("ep01.maycast")
        _ = try harness.run(["init", episode.path])

        let assetsDir = episode.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        let outroURL = assetsDir.appendingPathComponent("outro.wav")
        let outroBuf = AudioIO.sineWave(frequency: 660, duration: 1.0, amplitude: 0.3, sampleRate: 44100)
        try AudioIO.writeWAV(outroBuf, to: outroURL)

        let manifestURL = episode.appendingPathComponent("episode.json")
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
        manifest["mix"] = [
            "outro": "assets/outro.wav",
            "introOffsetSec": 2.0,
            "outroOffsetSec": 0.5,
            "duckingGainDB": -12,
            "duckingFadeSec": 0.5,
        ] as [String: Any]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted]).write(to: manifestURL)

        let host = workspace.appendingPathComponent("host.wav")
        try harness.writeSineWaveWAV(at: host, frequency: 333, duration: 2.0, sampleRate: 48000)
        _ = try harness.run(["import", "-project", episode.path, "--as", "host", host.path])

        let result = try harness.run([
            "mix", "-project", episode.path, "--output", "exports/ep01.m4a",
        ])
        #expect(result.succeeded, "stderr: \(result.stderr)")
        let buffer = try AudioIO.read(from: episode.appendingPathComponent("exports/ep01.m4a"))
        // voice 2s + outro 1s - outroOffset 0.5s = 2.5s
        #expect(abs(buffer.duration - 2.5) < 0.05, "expected ~2.5s, got \(buffer.duration)")
    }

    @Test
    func mixSurvivesSilentTrack() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }
        let episode = workspace.appendingPathComponent("ep01.maycast")
        _ = try harness.run(["init", episode.path])

        let host = workspace.appendingPathComponent("host.wav")
        let guest = workspace.appendingPathComponent("guest.wav")
        try harness.writeSineWaveWAV(at: host, frequency: 333, duration: 1.0)
        try harness.writeSilentWAV(at: guest, duration: 1.0)
        _ = try harness.run(["import", "-project", episode.path, "--as", "host",  host.path])
        _ = try harness.run(["import", "-project", episode.path, "--as", "guest", guest.path])

        _ = try harness.run(["mix", "-project", episode.path, "--output", "exports/ep01.m4a"])
        let buffer = try AudioIO.read(from: episode.appendingPathComponent("exports/ep01.m4a"))

        let leftRMS = sqrt(buffer.samples[0].reduce(0.0) { $0 + Double($1 * $1) } / Double(buffer.frameCount))
        // Should be ≈ host's RMS (≈ 0.354)
        #expect(leftRMS > 0.3 && leftRMS < 0.5, "expected ≈0.35 (host alone), got \(leftRMS)")
    }
}

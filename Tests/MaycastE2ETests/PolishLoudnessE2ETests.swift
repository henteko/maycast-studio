import Testing
import Foundation
import MaycastCore

@Suite("polish (loudness)")
struct PolishLoudnessE2ETests {
    @Test
    func loudnessTargetMatchesAfterPolish() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }

        let episode = workspace.appendingPathComponent("ep01.maycast")
        _ = try harness.run(["init", episode.path])

        // 3 seconds is enough for several 400 ms gating blocks.
        let host = workspace.appendingPathComponent("host.wav")
        try harness.writeSineWaveWAV(at: host, frequency: 333, duration: 3.0)
        _ = try harness.run(["import", "-project", episode.path, "--as", "host", host.path])

        let result = try harness.run([
            "polish", "-project", episode.path, "--track", "host", "--loudness", "-16",
        ])
        #expect(result.succeeded, "stderr: \(result.stderr)\nstdout: \(result.stdout)")

        let outputURL = episode.appendingPathComponent("intermediate/host/002_polish.wav")
        let buffer = try AudioIO.read(from: outputURL)
        let measured = Loudness.integratedLUFS(buffer)
        #expect(measured != nil)
        if let lufs = measured {
            #expect(abs(lufs - (-16)) < 1.0, "expected LUFS ≈ -16, got \(lufs)")
        }
    }

    @Test
    func loudnessChangesOnlyAmplitudeNotDuration() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }

        let episode = workspace.appendingPathComponent("ep01.maycast")
        _ = try harness.run(["init", episode.path])
        let host = workspace.appendingPathComponent("host.wav")
        try harness.writeSineWaveWAV(at: host, frequency: 333, duration: 2.0)
        _ = try harness.run(["import", "-project", episode.path, "--as", "host", host.path])

        let beforeURL = episode.appendingPathComponent("intermediate/host/001_import.wav")
        let beforeBuffer = try AudioIO.read(from: beforeURL)

        _ = try harness.run([
            "polish", "-project", episode.path, "--track", "host", "--loudness", "-20",
        ])

        let afterURL = episode.appendingPathComponent("intermediate/host/002_polish.wav")
        let afterBuffer = try AudioIO.read(from: afterURL)

        #expect(afterBuffer.frameCount == beforeBuffer.frameCount)
        #expect(afterBuffer.sampleRate == beforeBuffer.sampleRate)
        #expect(afterBuffer.channelCount == beforeBuffer.channelCount)
    }
}

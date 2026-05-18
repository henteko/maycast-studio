import Testing
import Foundation
import MaycastCore

@Suite("silence-removal (cross-track)")
struct SilenceRemovalE2ETests {
    /// Build a wav with alternating tone/silence segments.
    private func writeSegments(at url: URL, segments: [Seg], sampleRate: Double = 16000) throws {
        var samples: [Float] = []
        for seg in segments {
            switch seg {
            case .silence(let dur):
                samples.append(contentsOf: repeatElement(0, count: Int(dur * sampleRate)))
            case .tone(let dur, let freq):
                let n = Int(dur * sampleRate)
                for i in 0..<n {
                    let t = Double(i) / sampleRate
                    samples.append(Float(0.3 * sin(2 * .pi * freq * t)))
                }
            }
        }
        let buffer = AudioBuffer(sampleRate: sampleRate, channelCount: 1, samples: [samples])
        try AudioIO.writeWAV(buffer, to: url)
    }

    private enum Seg {
        case silence(Double)
        case tone(Double, freq: Double)
    }

    private func setupEpisode(harness: E2EHarness, workspace: URL, hostSegs: [Seg], guestSegs: [Seg]) throws -> URL {
        let episodePath = workspace.appendingPathComponent("ep01.maycast")
        _ = try harness.run(["init", episodePath.path])

        let host = workspace.appendingPathComponent("host.wav")
        try writeSegments(at: host, segments: hostSegs)
        _ = try harness.run(["import", "-project", episodePath.path, "--as", "host", host.path])

        let guest = workspace.appendingPathComponent("guest.wav")
        try writeSegments(at: guest, segments: guestSegs)
        _ = try harness.run(["import", "-project", episodePath.path, "--as", "guest", guest.path])

        return episodePath
    }

    @Test
    func commonSilenceIsRemovedFromBothTracks() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }

        // Both tracks: tone 0–1, silence 1–2, tone 2–3 (1s of shared silence).
        // Use distinct frequencies so the tracks aren't identical.
        let episode = try setupEpisode(
            harness: harness, workspace: workspace,
            hostSegs:  [.tone(1.0, freq: 330), .silence(1.0), .tone(1.0, freq: 330)],
            guestSegs: [.tone(1.0, freq: 220), .silence(1.0), .tone(1.0, freq: 220)]
        )

        // padding=0 so the math is exact.
        let result = try harness.run([
            "silence-removal", "-project", episode.path,
            "--threshold", "0.01", "--min-duration", "0.3", "--padding", "0",
        ])
        #expect(result.succeeded, "stderr: \(result.stderr)")

        let hostGen = episode.appendingPathComponent("intermediate/host/002_silence_removal.wav")
        let guestGen = episode.appendingPathComponent("intermediate/guest/002_silence_removal.wav")
        let hostBuf = try AudioIO.read(from: hostGen)
        let guestBuf = try AudioIO.read(from: guestGen)
        // Original 3s → minus the 1s common silence → ~2s.
        #expect(abs(hostBuf.duration - 2.0) < 0.05)
        #expect(abs(guestBuf.duration - 2.0) < 0.05)
    }

    @Test
    func staggeredSilenceLeavesAudioUnchanged() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }

        // host:  silent 0–1, tone 1–3
        // guest: tone 0–2, silent 2–3
        // → no time where both are silent → no cuts → no new generation
        let episode = try setupEpisode(
            harness: harness, workspace: workspace,
            hostSegs:  [.silence(1.0), .tone(2.0, freq: 330)],
            guestSegs: [.tone(2.0, freq: 220), .silence(1.0)]
        )

        let result = try harness.run([
            "silence-removal", "-project", episode.path,
            "--threshold", "0.01", "--min-duration", "0.3", "--padding", "0",
        ])
        #expect(result.succeeded, "stderr: \(result.stderr)")
        #expect(result.stdout.contains("No cross-track silent regions"))

        // No new generations were created.
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: episode.appendingPathComponent("intermediate/host/002_silence_removal.wav").path))
        #expect(!fm.fileExists(atPath: episode.appendingPathComponent("intermediate/guest/002_silence_removal.wav").path))
    }

    @Test
    func paddingShortensTheCut() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }

        // Both tracks: 1s tone, 2s silence, 1s tone — 4s total, 2s common silence.
        let episode = try setupEpisode(
            harness: harness, workspace: workspace,
            hostSegs:  [.tone(1.0, freq: 330), .silence(2.0), .tone(1.0, freq: 330)],
            guestSegs: [.tone(1.0, freq: 220), .silence(2.0), .tone(1.0, freq: 220)]
        )

        // padding=0.2 → only the inner 1.6s is cut → output is 4 - 1.6 = 2.4s.
        let result = try harness.run([
            "silence-removal", "-project", episode.path,
            "--threshold", "0.01", "--min-duration", "0.5", "--padding", "0.2",
        ])
        #expect(result.succeeded, "stderr: \(result.stderr)")

        let hostGen = episode.appendingPathComponent("intermediate/host/002_silence_removal.wav")
        let buf = try AudioIO.read(from: hostGen)
        #expect(abs(buf.duration - 2.4) < 0.05)
    }
}

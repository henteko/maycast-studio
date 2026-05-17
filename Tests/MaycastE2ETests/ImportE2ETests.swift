import Testing
import Foundation
import MaycastCore

@Suite("maycast import")
struct ImportE2ETests {
    @Test
    func importCopiesSourceAndCreatesGeneration() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }

        let episodePath = workspace.appendingPathComponent("ep01.maycast")
        _ = try harness.run(["init", episodePath.path])

        let host = workspace.appendingPathComponent("host.wav")
        try harness.writeSilentWAV(at: host, duration: 1.0)

        let result = try harness.run([
            "import",
            "-project", episodePath.path,
            "--as", "host",
            host.path,
        ])
        #expect(result.succeeded, "stderr: \(result.stderr)\nstdout: \(result.stdout)")

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: episodePath.appendingPathComponent("sources/host.wav").path))
        let firstGen = episodePath.appendingPathComponent("intermediate/host/001_import.wav")
        #expect(fm.fileExists(atPath: firstGen.path))
        #expect(fm.fileExists(atPath: episodePath.appendingPathComponent("intermediate/host/001_import.params.json").path))
        #expect(fm.fileExists(atPath: episodePath.appendingPathComponent("intermediate/host/001_import.transcript.json").path))

        // The imported file should decode as valid audio with the expected duration.
        let buffer = try AudioIO.read(from: firstGen)
        #expect(abs(buffer.duration - 1.0) < 0.05)
        #expect(buffer.channelCount == 1)

        let json = try Data(contentsOf: episodePath.appendingPathComponent("episode.json"))
        let decoded = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        let tracks = decoded?["tracks"] as? [[String: Any]]
        #expect(tracks?.count == 1)
        let host0 = tracks?.first
        #expect(host0?["id"] as? String == "host")
        #expect(host0?["source"] as? String == "sources/host.wav")
        #expect(host0?["current"] as? String == "intermediate/host/001_import.wav")
        let history = host0?["history"] as? [String]
        #expect(history == ["intermediate/host/001_import.wav"])
    }

    @Test
    func importTwoTracksAddsBoth() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }

        let episodePath = workspace.appendingPathComponent("ep01.maycast")
        _ = try harness.run(["init", episodePath.path])

        let host = workspace.appendingPathComponent("host.wav")
        let guest = workspace.appendingPathComponent("guest.wav")
        try harness.writeSilentWAV(at: host, duration: 0.5)
        try harness.writeSilentWAV(at: guest, duration: 0.5)

        _ = try harness.run(["import", "-project", episodePath.path, "--as", "host", host.path])
        _ = try harness.run(["import", "-project", episodePath.path, "--as", "guest", guest.path])

        let json = try Data(contentsOf: episodePath.appendingPathComponent("episode.json"))
        let decoded = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        let tracks = decoded?["tracks"] as? [[String: Any]]
        #expect(tracks?.count == 2)
        #expect(tracks?.contains(where: { $0["id"] as? String == "host" }) == true)
        #expect(tracks?.contains(where: { $0["id"] as? String == "guest" }) == true)
    }
}

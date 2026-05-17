import Testing
import Foundation

@Suite("operations (transcribe / slice / polish / mix)")
struct OperationsE2ETests {
    private func setupEpisodeWithHost(harness: E2EHarness, workspace: URL) throws -> URL {
        let episodePath = workspace.appendingPathComponent("ep01.maycast")
        _ = try harness.run(["init", episodePath.path])
        let host = workspace.appendingPathComponent("host.wav")
        try harness.writeDummyAudio(at: host, content: "HOST")
        _ = try harness.run(["import", "-project", episodePath.path, "--as", "host", host.path])
        return episodePath
    }

    @Test
    func transcribeOverwritesCurrentTranscript() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }
        let episode = try setupEpisodeWithHost(harness: harness, workspace: workspace)

        let result = try harness.run(["transcribe", "-project", episode.path, "--track", "host"])
        #expect(result.succeeded, "stderr: \(result.stderr)\nstdout: \(result.stdout)")

        let transcriptURL = episode.appendingPathComponent("intermediate/host/001_import.transcript.json")
        let data = try Data(contentsOf: transcriptURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let segments = json?["segments"] as? [[String: Any]]
        #expect(segments?.count == 1)
        #expect(segments?.first?["text"] as? String == "[stub-transcript]")
    }

    @Test
    func sliceCreatesNextGeneration() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }
        let episode = try setupEpisodeWithHost(harness: harness, workspace: workspace)

        let result = try harness.run([
            "slice", "-project", episode.path, "--track", "host", "--cut", "12.3-15.8",
        ])
        #expect(result.succeeded, "stderr: \(result.stderr)\nstdout: \(result.stdout)")

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: episode.appendingPathComponent("intermediate/host/002_slice.wav").path))
        #expect(fm.fileExists(atPath: episode.appendingPathComponent("intermediate/host/002_slice.params.json").path))
        #expect(fm.fileExists(atPath: episode.appendingPathComponent("intermediate/host/002_slice.transcript.json").path))

        let manifest = try Data(contentsOf: episode.appendingPathComponent("episode.json"))
        let decoded = try JSONSerialization.jsonObject(with: manifest) as? [String: Any]
        let tracks = decoded?["tracks"] as? [[String: Any]]
        let host = tracks?.first(where: { $0["id"] as? String == "host" })
        #expect(host?["current"] as? String == "intermediate/host/002_slice.wav")
        #expect((host?["history"] as? [String])?.count == 2)
    }

    @Test
    func polishCreatesNextGeneration() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }
        let episode = try setupEpisodeWithHost(harness: harness, workspace: workspace)

        let result = try harness.run([
            "polish", "-project", episode.path, "--track", "host", "--denoise", "--loudness", "-16",
        ])
        #expect(result.succeeded, "stderr: \(result.stderr)\nstdout: \(result.stdout)")

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: episode.appendingPathComponent("intermediate/host/002_polish.wav").path))

        let paramsURL = episode.appendingPathComponent("intermediate/host/002_polish.params.json")
        let data = try Data(contentsOf: paramsURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["op"] as? String == "polish")
        let params = json?["params"] as? [String: Any]
        #expect(params?["denoise"] as? Bool == true)
        #expect(params?["loudness"] as? Double == -16)
    }

    @Test
    func sliceThenPolishThenSlice() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }
        let episode = try setupEpisodeWithHost(harness: harness, workspace: workspace)

        _ = try harness.run(["slice", "-project", episode.path, "--track", "host", "--cut", "1.0-2.0"])
        _ = try harness.run(["polish", "-project", episode.path, "--track", "host", "--denoise"])
        let final = try harness.run(["slice", "-project", episode.path, "--track", "host", "--cut", "3.0-4.0"])
        #expect(final.succeeded, "stderr: \(final.stderr)")

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: episode.appendingPathComponent("intermediate/host/002_slice.wav").path))
        #expect(fm.fileExists(atPath: episode.appendingPathComponent("intermediate/host/003_polish.wav").path))
        #expect(fm.fileExists(atPath: episode.appendingPathComponent("intermediate/host/004_slice.wav").path))

        let manifest = try Data(contentsOf: episode.appendingPathComponent("episode.json"))
        let decoded = try JSONSerialization.jsonObject(with: manifest) as? [String: Any]
        let tracks = decoded?["tracks"] as? [[String: Any]]
        let host = tracks?.first(where: { $0["id"] as? String == "host" })
        #expect(host?["current"] as? String == "intermediate/host/004_slice.wav")
    }

    @Test
    func mixProducesExport() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }
        let episode = try setupEpisodeWithHost(harness: harness, workspace: workspace)

        let outputPath = "exports/ep01.wav"
        let result = try harness.run(["mix", "-project", episode.path, "--output", outputPath])
        #expect(result.succeeded, "stderr: \(result.stderr)")
        #expect(FileManager.default.fileExists(atPath: episode.appendingPathComponent(outputPath).path))
    }
}

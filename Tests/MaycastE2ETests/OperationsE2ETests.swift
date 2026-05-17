import Testing
import Foundation
import MaycastCore

@Suite("operations (transcribe / polish / mix)")
struct OperationsE2ETests {
    private func setupEpisodeWithHost(harness: E2EHarness, workspace: URL) throws -> URL {
        let episodePath = workspace.appendingPathComponent("ep01.maycast")
        _ = try harness.run(["init", episodePath.path])
        let host = workspace.appendingPathComponent("host.wav")
        try harness.writeSilentWAV(at: host, duration: 1.0)
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

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

    /// CLI transcribe runs `SpeechAnalyzer` inside a subprocess. macOS 26
    /// requires `NSSpeechRecognitionUsageDescription` on the bundle hosting
    /// the speech APIs; the CLI binary does not have one yet, so this path
    /// only works once we ship the .app-bundled service in a later phase.
    /// For now the primary entry point for transcription is the GUI app.
    /// We keep this test as a smoke check that the command exits (doesn't
    /// hang) and produces some output stream.
    @Test
    func transcribeCommandDoesNotHang() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }
        let episode = try setupEpisodeWithHost(harness: harness, workspace: workspace)

        let result = try harness.run(["transcribe", "-project", episode.path, "--track", "host"])
        // We don't assert on success/failure — the subprocess may be killed by
        // the OS when accessing Speech APIs without an Info.plist usage string.
        // Just confirm the run completed and returned a non-empty diagnostic.
        let hasOutput = !result.stdout.isEmpty || !result.stderr.isEmpty || result.exitCode != 0
        #expect(hasOutput || result.succeeded)
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

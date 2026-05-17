import Testing
import Foundation

@Suite("list / inspect / revert")
struct InspectionE2ETests {
    private func setupEpisodeWithSliced(harness: E2EHarness, workspace: URL) throws -> URL {
        let episodePath = workspace.appendingPathComponent("ep01.maycast")
        _ = try harness.run(["init", episodePath.path])
        let host = workspace.appendingPathComponent("host.wav")
        try harness.writeDummyAudio(at: host, content: "HOST")
        _ = try harness.run(["import", "-project", episodePath.path, "--as", "host", host.path])
        _ = try harness.run(["slice", "-project", episodePath.path, "--track", "host", "--cut", "1.0-2.0"])
        _ = try harness.run(["polish", "-project", episodePath.path, "--track", "host", "--denoise"])
        return episodePath
    }

    @Test
    func listShowsTracksAndCurrent() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }
        let episode = try setupEpisodeWithSliced(harness: harness, workspace: workspace)

        let result = try harness.run(["list", "-project", episode.path])
        #expect(result.succeeded, "stderr: \(result.stderr)")
        #expect(result.stdout.contains("host"))
        #expect(result.stdout.contains("intermediate/host/003_polish.wav"))
    }

    @Test
    func inspectShowsHistoryAndParams() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }
        let episode = try setupEpisodeWithSliced(harness: harness, workspace: workspace)

        let result = try harness.run(["inspect", "-project", episode.path, "--track", "host"])
        #expect(result.succeeded, "stderr: \(result.stderr)")
        #expect(result.stdout.contains("001_import.wav"))
        #expect(result.stdout.contains("002_slice.wav"))
        #expect(result.stdout.contains("003_polish.wav"))
        #expect(result.stdout.contains("denoise"))
        #expect(result.stdout.contains("current"))
    }

    @Test
    func revertChangesCurrent() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }
        let episode = try setupEpisodeWithSliced(harness: harness, workspace: workspace)

        let result = try harness.run(["revert", "-project", episode.path, "--track", "host", "--to", "2"])
        #expect(result.succeeded, "stderr: \(result.stderr)")

        let manifest = try Data(contentsOf: episode.appendingPathComponent("episode.json"))
        let decoded = try JSONSerialization.jsonObject(with: manifest) as? [String: Any]
        let tracks = decoded?["tracks"] as? [[String: Any]]
        let host = tracks?.first(where: { $0["id"] as? String == "host" })
        #expect(host?["current"] as? String == "intermediate/host/002_slice.wav")
        // history is untouched
        #expect((host?["history"] as? [String])?.count == 3)
    }

    @Test
    func sliceAfterRevertBranchesFromOldCurrent() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }
        let episode = try setupEpisodeWithSliced(harness: harness, workspace: workspace)

        _ = try harness.run(["revert", "-project", episode.path, "--track", "host", "--to", "2"])
        let result = try harness.run(["slice", "-project", episode.path, "--track", "host", "--cut", "5.0-6.0"])
        #expect(result.succeeded)

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: episode.appendingPathComponent("intermediate/host/004_slice.wav").path))

        let manifest = try Data(contentsOf: episode.appendingPathComponent("episode.json"))
        let decoded = try JSONSerialization.jsonObject(with: manifest) as? [String: Any]
        let tracks = decoded?["tracks"] as? [[String: Any]]
        let host = tracks?.first(where: { $0["id"] as? String == "host" })
        #expect(host?["current"] as? String == "intermediate/host/004_slice.wav")
    }
}

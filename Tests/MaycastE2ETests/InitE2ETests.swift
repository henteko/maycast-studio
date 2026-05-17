import Testing
import Foundation

@Suite("maycast init")
struct InitE2ETests {
    @Test
    func createsStandaloneEpisode() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }

        let episodePath = workspace.appendingPathComponent("ep01.maycast")
        let result = try harness.run(["init", episodePath.path])
        #expect(result.succeeded, "stderr: \(result.stderr)\nstdout: \(result.stdout)")

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: episodePath.path))
        #expect(fm.fileExists(atPath: episodePath.appendingPathComponent("episode.json").path))
        #expect(fm.fileExists(atPath: episodePath.appendingPathComponent("sources").path))
        #expect(fm.fileExists(atPath: episodePath.appendingPathComponent("intermediate").path))
        #expect(fm.fileExists(atPath: episodePath.appendingPathComponent("assets").path))
        #expect(fm.fileExists(atPath: episodePath.appendingPathComponent("exports").path))

        let json = try Data(contentsOf: episodePath.appendingPathComponent("episode.json"))
        let decoded = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        #expect(decoded?["id"] as? String == "ep01")
        #expect(decoded?["uuid"] is String)
        #expect(decoded?["show"] == nil)
        #expect((decoded?["tracks"] as? [Any])?.isEmpty == true)
    }

    @Test
    func failsIfBundleAlreadyExists() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }

        let episodePath = workspace.appendingPathComponent("ep01.maycast")
        let first = try harness.run(["init", episodePath.path])
        #expect(first.succeeded)

        let second = try harness.run(["init", episodePath.path])
        #expect(!second.succeeded)
        #expect(second.stderr.contains("already exists") || second.stdout.contains("already exists"))
    }
}

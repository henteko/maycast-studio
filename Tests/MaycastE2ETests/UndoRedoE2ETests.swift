import Testing
import Foundation
import MaycastCore

@Suite("maycast undo / redo")
struct UndoRedoE2ETests {
    private func setupHost(harness: E2EHarness, workspace: URL) throws -> URL {
        let episode = workspace.appendingPathComponent("ep01.maycast")
        _ = try harness.run(["init", episode.path])
        let host = workspace.appendingPathComponent("host.wav")
        try harness.writeSineWaveWAV(at: host, frequency: 440, duration: 4.0)
        _ = try harness.run(["import", "-project", episode.path, "--as", "host", host.path])
        return episode
    }

    private func currentPath(in episode: URL, trackID: String) throws -> String {
        let data = try Data(contentsOf: episode.appendingPathComponent("episode.json"))
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let tracks = decoded?["tracks"] as? [[String: Any]]
        guard let track = tracks?.first(where: { $0["id"] as? String == trackID }) else {
            return ""
        }
        return (track["current"] as? String) ?? ""
    }

    @Test
    func undoOnFreshBundleReportsNothingToUndo() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }
        let episode = try setupHost(harness: harness, workspace: workspace)

        let result = try harness.run(["undo", "-project", episode.path])
        #expect(result.succeeded, "stderr: \(result.stderr)")
        #expect(result.stdout.contains("Nothing to undo"))
    }

    @Test
    func undoRedoFlowsThroughTwoSliceOperations() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }
        let episode = try setupHost(harness: harness, workspace: workspace)
        let g1 = try currentPath(in: episode, trackID: "host")  // 001_import.wav

        // 1) First slice (split) → 002_slice.wav.
        let arr1 = try JSONDecoder().decode(
            Arrangement.self,
            from: Data(contentsOf: episode.appendingPathComponent("intermediate/host/001_import.arrangement.json"))
        )
        let clipID1 = arr1.clips[0].id
        _ = try harness.run([
            "slice", "split", "-project", episode.path, "--track", "host",
            "--clip", clipID1, "--at", "2.0",
        ])
        let g2 = try currentPath(in: episode, trackID: "host")
        #expect(g2.contains("002_slice"))

        // 2) Second slice (split) → 003_slice.wav.
        let arr2 = try JSONDecoder().decode(
            Arrangement.self,
            from: Data(contentsOf: episode.appendingPathComponent("intermediate/host/002_slice.arrangement.json"))
        )
        let clipID2 = arr2.clips[0].id
        _ = try harness.run([
            "slice", "split", "-project", episode.path, "--track", "host",
            "--clip", clipID2, "--at", "1.0",
        ])
        let g3 = try currentPath(in: episode, trackID: "host")
        #expect(g3.contains("003_slice"))

        // 3) Undo → back to g2.
        let undo1 = try harness.run(["undo", "-project", episode.path])
        #expect(undo1.succeeded, "stderr: \(undo1.stderr)")
        #expect(try currentPath(in: episode, trackID: "host") == g2)

        // 4) Undo again → back to g1.
        _ = try harness.run(["undo", "-project", episode.path])
        #expect(try currentPath(in: episode, trackID: "host") == g1)

        // 5) Undo once more → nothing to undo.
        let undoEmpty = try harness.run(["undo", "-project", episode.path])
        #expect(undoEmpty.stdout.contains("Nothing to undo"))
        #expect(try currentPath(in: episode, trackID: "host") == g1)

        // 6) Redo → g2.
        _ = try harness.run(["redo", "-project", episode.path])
        #expect(try currentPath(in: episode, trackID: "host") == g2)

        // 7) Redo → g3.
        _ = try harness.run(["redo", "-project", episode.path])
        #expect(try currentPath(in: episode, trackID: "host") == g3)
    }

    @Test
    func newOperationAfterUndoClearsRedoStack() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }
        let episode = try setupHost(harness: harness, workspace: workspace)

        // slice → undo → another slice → redo should be a no-op.
        let arr = try JSONDecoder().decode(
            Arrangement.self,
            from: Data(contentsOf: episode.appendingPathComponent("intermediate/host/001_import.arrangement.json"))
        )
        let clipID = arr.clips[0].id
        _ = try harness.run([
            "slice", "split", "-project", episode.path, "--track", "host",
            "--clip", clipID, "--at", "2.0",
        ])
        _ = try harness.run(["undo", "-project", episode.path])

        // Fresh op after undo branches the timeline.
        let arr2 = try JSONDecoder().decode(
            Arrangement.self,
            from: Data(contentsOf: episode.appendingPathComponent("intermediate/host/001_import.arrangement.json"))
        )
        let clipID2 = arr2.clips[0].id
        _ = try harness.run([
            "slice", "split", "-project", episode.path, "--track", "host",
            "--clip", clipID2, "--at", "3.0",
        ])

        let redoResult = try harness.run(["redo", "-project", episode.path])
        #expect(redoResult.stdout.contains("Nothing to redo"))
    }
}

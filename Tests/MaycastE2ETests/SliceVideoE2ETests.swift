import Testing
import Foundation
import MaycastCore

@Suite("slice → video cut (Phase 2)")
struct SliceVideoE2ETests {
    private func setupVideoEpisode(harness: E2EHarness, workspace: URL, duration: Double = 4.0) throws -> URL {
        let episodePath = workspace.appendingPathComponent("ep01.maycast")
        _ = try harness.run(["init", episodePath.path])
        let video = workspace.appendingPathComponent("host.mp4")
        try harness.writeTestVideo(at: video, duration: duration, frequency: 333)
        _ = try harness.run(["import", "-project", episodePath.path, "--as", "host", video.path])
        return episodePath
    }

    /// ffprobe the container duration (seconds), or -1 if it can't be read.
    private func duration(of url: URL, harness: E2EHarness) -> Double {
        let out = harness.ffprobe([
            "-v", "error", "-show_entries", "format=duration",
            "-of", "default=nw=1:nk=1", url.path,
        ]).trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(out) ?? -1
    }

    private func track(in episode: URL) throws -> [String: Any]? {
        let json = try Data(contentsOf: episode.appendingPathComponent("episode.json"))
        let decoded = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        return (decoded?["tracks"] as? [[String: Any]])?.first
    }

    /// Decode a track's cumulative `videoEdit` from episode.json (or nil).
    private func videoEdit(in episode: URL) throws -> Arrangement? {
        guard let track = try track(in: episode),
              let dict = track["videoEdit"] as? [String: Any] else { return nil }
        let data = try JSONSerialization.data(withJSONObject: dict)
        return try JSONDecoder().decode(Arrangement.self, from: data)
    }

    private func runSliceApply(_ harness: E2EHarness, _ episode: URL, _ workspace: URL, _ arr: Arrangement) throws {
        let arrFile = workspace.appendingPathComponent("cut-\(UUID().uuidString).json")
        try JSONEncoder().encode(arr).write(to: arrFile)
        let result = try harness.run([
            "slice", "apply", "-project", episode.path, "--track", "host",
            "--arrangement-file", arrFile.path,
        ])
        #expect(result.succeeded, "stderr: \(result.stderr)")
    }

    /// Slice records the cut as a cumulative `videoEdit` — it never encodes a
    /// video during editing (deferred rendering), so no per-slice video file
    /// exists and apply is instant.
    @Test
    func sliceComposesVideoEditWithoutEncoding() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }
        let episode = try setupVideoEpisode(harness: harness, workspace: workspace, duration: 4.0)

        // Keep only [0–2] of the source.
        try runSliceApply(harness, episode, workspace,
                          Arrangement(clips: [Clip(id: "a", sourceStart: 0, sourceEnd: 2.0, timelineStart: 0)]))

        // No video was rendered during the slice.
        #expect(!FileManager.default.fileExists(
            atPath: episode.appendingPathComponent("intermediate/host/002_slice.mp4").path))
        // Audio advanced; the cumulative video edit reflects the 2s cut.
        let track = try track(in: episode)
        #expect(track?["current"] as? String == "intermediate/host/002_slice.wav")
        let edit = try videoEdit(in: episode)
        #expect(abs((edit?.totalDuration ?? 0) - 2.0) < 1e-6)
    }

    /// After a slice, exporting renders the cut onto the original video and
    /// muxes the edited audio — picture and audio stay the same length.
    @Test
    func exportAfterSliceIsInSync() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }
        let episode = try setupVideoEpisode(harness: harness, workspace: workspace, duration: 4.0)

        try runSliceApply(harness, episode, workspace,
                          Arrangement(clips: [Clip(id: "a", sourceStart: 0, sourceEnd: 2.0, timelineStart: 0)]))

        let result = try harness.run(["render", "-project", episode.path])
        #expect(result.succeeded, "stderr: \(result.stderr)")

        let mp4 = episode.appendingPathComponent("exports/host.mp4")
        #expect(FileManager.default.fileExists(atPath: mp4.path))
        #expect(abs(duration(of: mp4, harness: harness) - 2.0) < 0.3)
    }

    /// A slice that leaves a gap (clip placed later) keeps the picture rolling
    /// at export, so the exported mp4 spans the full timeline (~4s).
    @Test
    func gapKeepsVideoRollingAtExport() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }
        let episode = try setupVideoEpisode(harness: harness, workspace: workspace, duration: 4.0)

        // Keep [2–4] at timeline 2 → 0..2 is a gap (audio silent, video rolls).
        try runSliceApply(harness, episode, workspace,
                          Arrangement(clips: [Clip(id: "a", sourceStart: 2.0, sourceEnd: 4.0, timelineStart: 2.0)]))
        _ = try harness.run(["render", "-project", episode.path])

        let mp4 = episode.appendingPathComponent("exports/host.mp4")
        #expect(abs(duration(of: mp4, harness: harness) - 4.0) < 0.3)
    }

    /// Undo moves the cumulative video edit back alongside the audio.
    @Test
    func undoRestoresVideoEdit() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }
        let episode = try setupVideoEpisode(harness: harness, workspace: workspace, duration: 4.0)

        try runSliceApply(harness, episode, workspace,
                          Arrangement(clips: [Clip(id: "a", sourceStart: 0, sourceEnd: 2.0, timelineStart: 0)]))
        #expect(abs((try videoEdit(in: episode)?.totalDuration ?? 0) - 2.0) < 1e-6)

        let undo = try harness.run(["undo", "-project", episode.path])
        #expect(undo.succeeded, "stderr: \(undo.stderr)")

        let track = try track(in: episode)
        #expect(track?["current"] as? String == "intermediate/host/001_import.wav")
        // Video edit reverted to the identity (whole ~4s original).
        #expect(abs((try videoEdit(in: episode)?.totalDuration ?? 0) - 4.0) < 0.2)
    }
}

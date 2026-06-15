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

    /// Applying a slice that keeps only the first half cuts the video to match,
    /// producing a parallel video generation on the new audio timeline.
    @Test
    func sliceCutsVideoToMatchAudio() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }
        let episode = try setupVideoEpisode(harness: harness, workspace: workspace, duration: 4.0)

        // Keep only [0–2] of the source — the result is a 2s clip.
        let arr = Arrangement(clips: [Clip(id: "a", sourceStart: 0, sourceEnd: 2.0, timelineStart: 0)])
        let arrFile = workspace.appendingPathComponent("cut.json")
        try JSONEncoder().encode(arr).write(to: arrFile)

        let result = try harness.run([
            "slice", "apply", "-project", episode.path, "--track", "host",
            "--arrangement-file", arrFile.path,
        ])
        #expect(result.succeeded, "stderr: \(result.stderr)")

        // A parallel video generation was produced.
        let cutVideo = episode.appendingPathComponent("intermediate/host/002_slice.mp4")
        #expect(FileManager.default.fileExists(atPath: cutVideo.path))
        #expect(abs(duration(of: cutVideo, harness: harness) - 2.0) < 0.25,
                "cut video should be ~2s")

        // The video chain advanced in lockstep with the audio chain.
        let track = try track(in: episode)
        #expect(track?["videoCurrent"] as? String == "intermediate/host/002_slice.mp4")
        #expect(track?["current"] as? String == "intermediate/host/002_slice.wav")
        let videoHistory = track?["videoHistory"] as? [String]
        #expect(videoHistory == ["sources/host.mp4", "intermediate/host/002_slice.mp4"])
    }

    /// A slice that leaves a gap (clip placed later on the timeline) produces a
    /// video of the full timeline length — the gap is black, mirroring the
    /// silence the audio render zero-fills.
    @Test
    func sliceWithGapExtendsVideoWithBlack() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }
        let episode = try setupVideoEpisode(harness: harness, workspace: workspace, duration: 4.0)

        // Keep [2–4] but place it at timeline 2 → 0..2 is a black gap, total 4s.
        let arr = Arrangement(clips: [Clip(id: "a", sourceStart: 2.0, sourceEnd: 4.0, timelineStart: 2.0)])
        let arrFile = workspace.appendingPathComponent("gap.json")
        try JSONEncoder().encode(arr).write(to: arrFile)

        let result = try harness.run([
            "slice", "apply", "-project", episode.path, "--track", "host",
            "--arrangement-file", arrFile.path,
        ])
        #expect(result.succeeded, "stderr: \(result.stderr)")

        let cutVideo = episode.appendingPathComponent("intermediate/host/002_slice.mp4")
        #expect(abs(duration(of: cutVideo, harness: harness) - 4.0) < 0.3,
                "video with a 2s gap + 2s clip should be ~4s")
    }

    /// After a slice, exporting muxes the cut video with the edited audio, and
    /// the two stay the same length (in sync).
    @Test
    func exportAfterSliceIsInSync() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }
        let episode = try setupVideoEpisode(harness: harness, workspace: workspace, duration: 4.0)

        let arr = Arrangement(clips: [Clip(id: "a", sourceStart: 0, sourceEnd: 2.0, timelineStart: 0)])
        let arrFile = workspace.appendingPathComponent("cut.json")
        try JSONEncoder().encode(arr).write(to: arrFile)
        _ = try harness.run(["slice", "apply", "-project", episode.path, "--track", "host",
                            "--arrangement-file", arrFile.path])

        let result = try harness.run(["export", "-project", episode.path])
        #expect(result.succeeded, "stderr: \(result.stderr)")

        let mp4 = episode.appendingPathComponent("exports/host.mp4")
        #expect(FileManager.default.fileExists(atPath: mp4.path))
        // The muxed mp4 is ~2s — picture and edited audio agree.
        #expect(abs(duration(of: mp4, harness: harness) - 2.0) < 0.3)
    }

    /// Undo moves the video chain back alongside the audio chain.
    @Test
    func undoRestoresVideoCurrent() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }
        let episode = try setupVideoEpisode(harness: harness, workspace: workspace, duration: 4.0)

        let arr = Arrangement(clips: [Clip(id: "a", sourceStart: 0, sourceEnd: 2.0, timelineStart: 0)])
        let arrFile = workspace.appendingPathComponent("cut.json")
        try JSONEncoder().encode(arr).write(to: arrFile)
        _ = try harness.run(["slice", "apply", "-project", episode.path, "--track", "host",
                            "--arrangement-file", arrFile.path])
        #expect(try track(in: episode)?["videoCurrent"] as? String == "intermediate/host/002_slice.mp4")

        let undo = try harness.run(["undo", "-project", episode.path])
        #expect(undo.succeeded, "stderr: \(undo.stderr)")

        let track = try track(in: episode)
        #expect(track?["current"] as? String == "intermediate/host/001_import.wav")
        #expect(track?["videoCurrent"] as? String == "sources/host.mp4")
    }
}

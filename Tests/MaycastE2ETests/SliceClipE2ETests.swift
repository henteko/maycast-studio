import Testing
import Foundation
import MaycastCore

@Suite("slice (clip arrangement)")
struct SliceClipE2ETests {
    private func setupEpisodeWithSineHost(harness: E2EHarness, workspace: URL, duration: Double = 4.0) throws -> URL {
        let episodePath = workspace.appendingPathComponent("ep01.maycast")
        _ = try harness.run(["init", episodePath.path])
        let host = workspace.appendingPathComponent("host.wav")
        // 333 Hz avoids zero-crossings at integer seconds.
        try harness.writeSineWaveWAV(at: host, frequency: 333, duration: duration)
        _ = try harness.run(["import", "-project", episodePath.path, "--as", "host", host.path])
        return episodePath
    }

    private func loadArrangement(at url: URL) throws -> Arrangement {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Arrangement.self, from: data)
    }

    @Test
    func importCreatesInitialArrangement() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }
        let episode = try setupEpisodeWithSineHost(harness: harness, workspace: workspace)

        let arrUrl = episode.appendingPathComponent("intermediate/host/001_import.arrangement.json")
        #expect(FileManager.default.fileExists(atPath: arrUrl.path))
        let arr = try loadArrangement(at: arrUrl)
        #expect(arr.clips.count == 1)
        #expect(arr.clips.first?.sourceStart == 0)
        #expect(abs((arr.clips.first?.sourceEnd ?? 0) - 4.0) < 0.05)
        #expect(arr.clips.first?.timelineStart == 0)
    }

    /// Slice operations always bake their edit into `current.wav` and then
    /// reset the on-disk arrangement to a single clip covering the rendered
    /// audio. The slice "history" lives in the audio itself, not in the
    /// arrangement metadata.

    @Test
    func splitResetsToSingleClipAndKeepsAudio() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }
        let episode = try setupEpisodeWithSineHost(harness: harness, workspace: workspace)

        let initial = try loadArrangement(at: episode.appendingPathComponent("intermediate/host/001_import.arrangement.json"))
        let clipID = initial.clips[0].id

        let result = try harness.run([
            "slice", "split",
            "-project", episode.path,
            "--track", "host",
            "--clip", clipID,
            "--at", "1.5",
        ])
        #expect(result.succeeded, "stderr: \(result.stderr)")

        // After save, arrangement is a single clip covering the whole rendered file.
        let newArr = try loadArrangement(at: episode.appendingPathComponent("intermediate/host/002_slice.arrangement.json"))
        #expect(newArr.clips.count == 1)
        #expect(abs(newArr.clips[0].timelineStart - 0) < 0.001)
        #expect(abs(newArr.totalDuration - 4.0) < 0.05)

        // Split does not change audio content.
        let rendered = try AudioIO.read(from: episode.appendingPathComponent("intermediate/host/002_slice.wav"))
        #expect(abs(rendered.duration - 4.0) < 0.05)
    }

    @Test
    func applyWithGapProducesSilentRegion() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }
        let episode = try setupEpisodeWithSineHost(harness: harness, workspace: workspace)

        // Apply an arrangement that keeps only [2.0–4.0] from the source —
        // dropping the first 2 seconds should leave silence in 0..2 of the
        // rendered file.
        let custom = Arrangement(clips: [
            Clip(id: "a", sourceStart: 2.0, sourceEnd: 4.0, timelineStart: 2.0)
        ])
        let arrFile = workspace.appendingPathComponent("custom.json")
        try JSONEncoder().encode(custom).write(to: arrFile)

        let result = try harness.run([
            "slice", "apply",
            "-project", episode.path,
            "--track", "host",
            "--arrangement-file", arrFile.path,
        ])
        #expect(result.succeeded, "stderr: \(result.stderr)")

        // Saved arrangement is reset to a single full-length clip.
        let saved = try loadArrangement(at: episode.appendingPathComponent("intermediate/host/002_slice.arrangement.json"))
        #expect(saved.clips.count == 1)
        #expect(abs(saved.clips[0].timelineStart - 0) < 0.001)
        #expect(abs(saved.totalDuration - 4.0) < 0.05)

        // The rendered audio: silent 0..2, signal 2..4.
        let buffer = try AudioIO.read(from: episode.appendingPathComponent("intermediate/host/002_slice.wav"))
        let sr = buffer.sampleRate
        let halfFrame = Int(2.0 * sr)
        let silenceRMS = sqrt(buffer.samples[0][0..<halfFrame]
            .reduce(0.0) { $0 + Double($1 * $1) } / Double(halfFrame))
        #expect(silenceRMS < 0.001, "expected silence in 0–2s, got RMS \(silenceRMS)")

        let audibleRMS = sqrt(buffer.samples[0][halfFrame..<buffer.frameCount]
            .reduce(0.0) { $0 + Double($1 * $1) } / Double(buffer.frameCount - halfFrame))
        #expect(audibleRMS > 0.3, "expected audio in 2–4s, got RMS \(audibleRMS)")
    }

    @Test
    func moveAddsLeadingSilenceAndExtendsDuration() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }
        let episode = try setupEpisodeWithSineHost(harness: harness, workspace: workspace)

        let initial = try loadArrangement(at: episode.appendingPathComponent("intermediate/host/001_import.arrangement.json"))
        let clipID = initial.clips[0].id

        let result = try harness.run([
            "slice", "move",
            "-project", episode.path,
            "--track", "host",
            "--clip", clipID,
            "--to", "5.0",
        ])
        #expect(result.succeeded, "stderr: \(result.stderr)")

        // Saved arrangement is single full-length clip (= 9s: 5s lead + 4s clip).
        let afterMove = try loadArrangement(at: episode.appendingPathComponent("intermediate/host/002_slice.arrangement.json"))
        #expect(afterMove.clips.count == 1)
        #expect(abs(afterMove.clips[0].timelineStart - 0) < 0.001)
        #expect(abs(afterMove.totalDuration - 9.0) < 0.05)

        let buffer = try AudioIO.read(from: episode.appendingPathComponent("intermediate/host/002_slice.wav"))
        #expect(abs(buffer.duration - 9.0) < 0.05)
        let sr = buffer.sampleRate
        let silenceFrame = Int(5.0 * sr)
        let leadRMS = sqrt(buffer.samples[0][0..<silenceFrame]
            .reduce(0.0) { $0 + Double($1 * $1) } / Double(silenceFrame))
        #expect(leadRMS < 0.001)
    }

    @Test
    func applyAtomicallyResetsArrangement() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }
        let episode = try setupEpisodeWithSineHost(harness: harness, workspace: workspace)

        // Custom arrangement with two clips and a gap (drop 1.0–2.5).
        let custom = Arrangement(clips: [
            Clip(id: "a", sourceStart: 0,   sourceEnd: 1.0, timelineStart: 0),
            Clip(id: "b", sourceStart: 2.5, sourceEnd: 4.0, timelineStart: 2.0),
        ])
        let arrangementFile = workspace.appendingPathComponent("custom.arrangement.json")
        try JSONEncoder().encode(custom).write(to: arrangementFile)

        let result = try harness.run([
            "slice", "apply",
            "-project", episode.path,
            "--track", "host",
            "--arrangement-file", arrangementFile.path,
        ])
        #expect(result.succeeded, "stderr: \(result.stderr)")

        // The saved arrangement is reset to a single clip — the input shape
        // (id "a"/"b", multiple clips) lives only in the audio.
        let applied = try loadArrangement(at: episode.appendingPathComponent("intermediate/host/002_slice.arrangement.json"))
        #expect(applied.clips.count == 1)
        #expect(abs(applied.clips[0].timelineStart - 0) < 0.001)
        #expect(abs(applied.totalDuration - 3.5) < 0.05)
    }

    @Test
    func polishCarriesArrangementForward() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }
        let episode = try setupEpisodeWithSineHost(harness: harness, workspace: workspace)

        let initial = try loadArrangement(at: episode.appendingPathComponent("intermediate/host/001_import.arrangement.json"))
        let clipID = initial.clips[0].id
        _ = try harness.run(["slice", "split", "-project", episode.path, "--track", "host", "--clip", clipID, "--at", "2.0"])
        let afterSlice = try loadArrangement(at: episode.appendingPathComponent("intermediate/host/002_slice.arrangement.json"))

        _ = try harness.run(["polish", "-project", episode.path, "--track", "host", "--denoise"])
        let afterPolish = try loadArrangement(at: episode.appendingPathComponent("intermediate/host/003_polish.arrangement.json"))

        // Both are single full-length clips (slice resets to single, polish
        // carries forward unchanged).
        #expect(afterPolish == afterSlice)
        #expect(afterSlice.clips.count == 1)
    }
}

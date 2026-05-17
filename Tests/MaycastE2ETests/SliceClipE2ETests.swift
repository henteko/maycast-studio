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

    @Test
    func splitProducesTwoClipsAtCorrectPositions() throws {
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

        let newArr = try loadArrangement(at: episode.appendingPathComponent("intermediate/host/002_slice.arrangement.json"))
        #expect(newArr.clips.count == 2)
        #expect(abs(newArr.clips[0].timelineStart - 0) < 0.001)
        #expect(abs(newArr.clips[0].sourceEnd - 1.5) < 0.001)
        #expect(abs(newArr.clips[1].timelineStart - 1.5) < 0.001)
        #expect(abs(newArr.clips[1].sourceStart - 1.5) < 0.001)
    }

    @Test
    func deleteLeavesSilentGap() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }
        let episode = try setupEpisodeWithSineHost(harness: harness, workspace: workspace)

        let initial = try loadArrangement(at: episode.appendingPathComponent("intermediate/host/001_import.arrangement.json"))
        let clipID = initial.clips[0].id

        // Split into two so we can delete just one.
        _ = try harness.run(["slice", "split", "-project", episode.path, "--track", "host", "--clip", clipID, "--at", "2.0"])
        let afterSplit = try loadArrangement(at: episode.appendingPathComponent("intermediate/host/002_slice.arrangement.json"))
        #expect(afterSplit.clips.count == 2)
        let firstClipID = afterSplit.clips[0].id

        // Delete the first clip → leaves silence 0..2, audio 2..4
        let result = try harness.run([
            "slice", "delete",
            "-project", episode.path,
            "--track", "host",
            "--clip", firstClipID,
        ])
        #expect(result.succeeded, "stderr: \(result.stderr)")

        let afterDelete = try loadArrangement(at: episode.appendingPathComponent("intermediate/host/003_slice.arrangement.json"))
        #expect(afterDelete.clips.count == 1)
        #expect(abs(afterDelete.clips[0].timelineStart - 2.0) < 0.001)
        #expect(abs(afterDelete.totalDuration - 4.0) < 0.001)

        // The rendered audio: silence 0..2, audio 2..4. Compare RMS in each region.
        let renderedURL = episode.appendingPathComponent("intermediate/host/003_slice.wav")
        let buffer = try AudioIO.read(from: renderedURL)
        let sr = buffer.sampleRate
        let halfFrame = Int(2.0 * sr)
        let silenceRMS = sqrt(buffer.samples[0][0..<halfFrame]
            .reduce(0.0) { $0 + Double($1 * $1) } / Double(halfFrame))
        #expect(silenceRMS < 0.001, "expected silence in 0–2s region, got RMS \(silenceRMS)")

        let audibleRMS = sqrt(buffer.samples[0][halfFrame..<buffer.frameCount]
            .reduce(0.0) { $0 + Double($1 * $1) } / Double(buffer.frameCount - halfFrame))
        #expect(audibleRMS > 0.3, "expected audio in 2–4s region, got RMS \(audibleRMS)")
    }

    @Test
    func moveUpdatesTimelineStart() throws {
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

        let afterMove = try loadArrangement(at: episode.appendingPathComponent("intermediate/host/002_slice.arrangement.json"))
        #expect(afterMove.clips.count == 1)
        #expect(abs(afterMove.clips[0].timelineStart - 5.0) < 0.001)
        #expect(abs(afterMove.totalDuration - 9.0) < 0.05)  // 5s silence + 4s clip
    }

    @Test
    func applyReplacesArrangement() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }
        let episode = try setupEpisodeWithSineHost(harness: harness, workspace: workspace)

        // Build a custom arrangement and persist to disk.
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

        let applied = try loadArrangement(at: episode.appendingPathComponent("intermediate/host/002_slice.arrangement.json"))
        #expect(applied.clips.count == 2)
        #expect(applied.clips[0].id == "a")
        #expect(applied.clips[1].id == "b")
        #expect(abs(applied.totalDuration - 3.5) < 0.001)
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

        #expect(afterPolish == afterSlice)
    }
}

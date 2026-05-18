import Testing
import Foundation
import MaycastCore

/// When a track's `current` changes (slice / polish / etc. produce a new
/// generation), the new generation's `transcript.json` should be **empty**.
/// The audio has changed, so any prior word timestamps are stale and must be
/// re-derived by re-running transcribe.
@Suite("transcript flush on current change")
struct TranscriptFlushE2ETests {
    private func setupWithTranscript(harness: E2EHarness, workspace: URL) throws -> URL {
        let episodePath = workspace.appendingPathComponent("ep01.maycast")
        _ = try harness.run(["init", episodePath.path])
        let host = workspace.appendingPathComponent("host.wav")
        try harness.writeSineWaveWAV(at: host, frequency: 333, duration: 4.0)
        _ = try harness.run(["import", "-project", episodePath.path, "--as", "host", host.path])

        // Seed the import generation's transcript with a couple of segments,
        // so we can prove the flush happened (not just "happened to be empty").
        let importTranscriptURL = episodePath.appendingPathComponent(
            "intermediate/host/001_import.transcript.json"
        )
        let seeded = Transcript(segments: [
            TranscriptSegment(start: 0.5, end: 1.0, text: "hello"),
            TranscriptSegment(start: 1.5, end: 2.0, text: "world"),
        ])
        try JSONCoders.encode(seeded, to: importTranscriptURL)
        return episodePath
    }

    private func loadTranscript(at url: URL) throws -> Transcript {
        try JSONCoders.decode(Transcript.self, from: url)
    }

    @Test
    func polishProducesEmptyTranscriptSidecar() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }
        let episode = try setupWithTranscript(harness: harness, workspace: workspace)

        let result = try harness.run([
            "polish", "-project", episode.path, "--track", "host", "--denoise",
        ])
        #expect(result.succeeded, "stderr: \(result.stderr)")

        // The import transcript still has the seeded segments…
        let importTr = try loadTranscript(
            at: episode.appendingPathComponent("intermediate/host/001_import.transcript.json")
        )
        #expect(importTr.segments.count == 2)

        // …but the polish generation's transcript is empty.
        let polishTr = try loadTranscript(
            at: episode.appendingPathComponent("intermediate/host/002_polish.transcript.json")
        )
        #expect(polishTr.segments.isEmpty)
    }

    @Test
    func sliceProducesEmptyTranscriptSidecar() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }
        let episode = try setupWithTranscript(harness: harness, workspace: workspace)

        // Apply a custom arrangement that drops the first 1s.
        let custom = Arrangement(clips: [
            Clip(id: "a", sourceStart: 1.0, sourceEnd: 4.0, timelineStart: 1.0)
        ])
        let arrangementFile = workspace.appendingPathComponent("custom.arrangement.json")
        try JSONEncoder().encode(custom).write(to: arrangementFile)

        let result = try harness.run([
            "slice", "apply",
            "-project", episode.path, "--track", "host",
            "--arrangement-file", arrangementFile.path,
        ])
        #expect(result.succeeded, "stderr: \(result.stderr)")

        // Seeded segments stay on the import generation.
        let importTr = try loadTranscript(
            at: episode.appendingPathComponent("intermediate/host/001_import.transcript.json")
        )
        #expect(importTr.segments.count == 2)

        // New slice generation has an empty transcript.
        let sliceTr = try loadTranscript(
            at: episode.appendingPathComponent("intermediate/host/002_slice.transcript.json")
        )
        #expect(sliceTr.segments.isEmpty)
    }

    @Test
    func successiveOperationsKeepCurrentTranscriptEmpty() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }
        let episode = try setupWithTranscript(harness: harness, workspace: workspace)

        // polish → slice; both new generations should be empty.
        _ = try harness.run(["polish", "-project", episode.path, "--track", "host", "--denoise"])
        let polishTrURL = episode.appendingPathComponent("intermediate/host/002_polish.transcript.json")
        // Re-seed the polish transcript so we can prove slice flushes that too.
        try JSONCoders.encode(
            Transcript(segments: [TranscriptSegment(start: 0, end: 0.5, text: "seeded")]),
            to: polishTrURL
        )

        let initial = try JSONCoders.decode(
            Arrangement.self,
            from: episode.appendingPathComponent("intermediate/host/002_polish.arrangement.json")
        )
        let clipID = initial.clips[0].id
        _ = try harness.run([
            "slice", "split",
            "-project", episode.path, "--track", "host",
            "--clip", clipID, "--at", "2.0",
        ])

        let sliceTr = try loadTranscript(
            at: episode.appendingPathComponent("intermediate/host/003_slice.transcript.json")
        )
        #expect(sliceTr.segments.isEmpty)
        // The seeded polish transcript is untouched on its own generation.
        let polishTr = try loadTranscript(at: polishTrURL)
        #expect(polishTr.segments.count == 1)
    }
}

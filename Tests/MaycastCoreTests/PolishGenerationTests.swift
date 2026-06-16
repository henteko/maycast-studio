import Testing
import Foundation
@testable import MaycastCore

/// Unit tests for `EpisodeBundle.appendPolishGeneration` — the Core plumbing
/// that ingests Auphonic output for both the audio and (for video tracks) the
/// video chain in lockstep. The Auphonic network round-trip itself lives in the
/// GUI and is verified manually; here we pin the deterministic model behavior.
@Suite("polish generation (audio + video chains)")
struct PolishGenerationTests {
    private func makeTempDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("maycast-polishgen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Build an episode with one track. When `video` is true the track carries a
    /// (dummy) video source so it exercises the video chain.
    private func makeEpisode(at workspace: URL, video: Bool) throws -> EpisodeBundle {
        let episodeURL = workspace.appendingPathComponent("ep01.maycast")
        var bundle = try EpisodeBundle.create(at: episodeURL)
        let fm = FileManager.default

        let firstGenRel = "intermediate/host/001_import.wav"
        let firstGen = episodeURL.appendingPathComponent(firstGenRel)
        try fm.createDirectory(at: firstGen.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AudioIO.writeWAV(AudioIO.silence(duration: 2.0, sampleRate: 48000, channelCount: 1), to: firstGen)

        var videoSource: String? = nil
        if video {
            let rel = "sources/host.mp4"
            let src = episodeURL.appendingPathComponent(rel)
            try fm.createDirectory(at: src.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "VIDEO".data(using: .utf8)!.write(to: src)
            videoSource = rel
        }

        let identity = Arrangement.single(sourceDuration: 2.0)
        bundle.upsertTrack(Track(
            id: "host",
            source: video ? "sources/host.mp4" : "sources/host.wav",
            current: firstGenRel,
            history: [firstGenRel],
            videoSource: videoSource,
            videoEdit: video ? identity : nil,
            videoEditHistory: video ? [identity] : nil
        ))
        try bundle.save()
        return bundle
    }

    @Test
    func polishVideoTrackComposesEditAndAdvancesAudio() throws {
        let workspace = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: workspace) }
        var bundle = try makeEpisode(at: workspace, video: true)

        // The "Auphonic output": a cleaned (shorter) WAV + the cut it applied,
        // expressed as a kept-region arrangement over the 2s current timeline
        // (drop 0.5–1.0 → kept [0,0.5] and [1.0,2.0]).
        let cleaned = workspace.appendingPathComponent("cleaned.wav")
        try AudioIO.writeWAV(AudioIO.silence(duration: 1.5, sampleRate: 48000, channelCount: 1), to: cleaned)
        let cut = Arrangement(clips: [
            Clip(sourceStart: 0, sourceEnd: 0.5, timelineStart: 0),
            Clip(sourceStart: 1.0, sourceEnd: 2.0, timelineStart: 0.5),
        ])

        let track = try bundle.appendPolishGeneration(
            trackID: "host",
            audioWAVSource: cleaned,
            videoCut: cut
        )

        // Audio advanced; the cumulative video edit got the cut composed in
        // (base was identity, so it equals the cut), and history is in lockstep.
        #expect(track.current == "intermediate/host/002_polish.wav")
        #expect(track.history == ["intermediate/host/001_import.wav", "intermediate/host/002_polish.wav"])
        #expect(track.videoEdit?.clips.count == 2)
        #expect(track.videoEditHistory?.count == 2)
        #expect(abs((track.videoEdit?.totalDuration ?? 0) - 1.5) < 1e-6)

        let root = workspace.appendingPathComponent("ep01.maycast")
        let buffer = try AudioIO.read(from: root.appendingPathComponent("intermediate/host/002_polish.wav"))
        #expect(abs(buffer.duration - 1.5) < 0.05)
    }

    @Test
    func undoMovesBothChainsBack() throws {
        let workspace = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: workspace) }
        var bundle = try makeEpisode(at: workspace, video: true)

        let cleaned = workspace.appendingPathComponent("cleaned.wav")
        try AudioIO.writeWAV(AudioIO.silence(duration: 1.5, sampleRate: 48000, channelCount: 1), to: cleaned)
        let cut = Arrangement(clips: [Clip(sourceStart: 0, sourceEnd: 1.5, timelineStart: 0)])

        _ = try bundle.appendPolishGeneration(trackID: "host", audioWAVSource: cleaned, videoCut: cut)
        _ = try bundle.undo()

        let track = bundle.track(withID: "host")!
        #expect(track.current == "intermediate/host/001_import.wav")
        // Video edit reverted to the identity (whole 2s source).
        #expect(abs((track.videoEdit?.totalDuration ?? 0) - 2.0) < 1e-6)
    }

    @Test
    func polishAudioOnlyTrackLeavesVideoEditAbsent() throws {
        let workspace = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: workspace) }
        var bundle = try makeEpisode(at: workspace, video: false)

        let cleaned = workspace.appendingPathComponent("cleaned.wav")
        try AudioIO.writeWAV(AudioIO.silence(duration: 1.5, sampleRate: 48000, channelCount: 1), to: cleaned)

        let track = try bundle.appendPolishGeneration(trackID: "host", audioWAVSource: cleaned, videoCut: nil)
        #expect(track.current == "intermediate/host/002_polish.wav")
        #expect(track.videoEdit == nil)
        #expect(track.videoEditHistory == nil)
    }
}

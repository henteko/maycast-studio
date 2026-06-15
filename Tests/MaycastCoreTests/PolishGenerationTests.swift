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

        bundle.upsertTrack(Track(
            id: "host",
            source: video ? "sources/host.mp4" : "sources/host.wav",
            current: firstGenRel,
            history: [firstGenRel],
            videoSource: videoSource,
            videoCurrent: videoSource,
            videoHistory: videoSource.map { [$0] }
        ))
        try bundle.save()
        return bundle
    }

    @Test
    func polishVideoTrackAdvancesBothChainsInLockstep() throws {
        let workspace = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: workspace) }
        var bundle = try makeEpisode(at: workspace, video: true)

        // The "Auphonic output": a cleaned (shorter) WAV + a processed video.
        let cleaned = workspace.appendingPathComponent("cleaned.wav")
        try AudioIO.writeWAV(AudioIO.silence(duration: 1.5, sampleRate: 48000, channelCount: 1), to: cleaned)
        let processedVideo = workspace.appendingPathComponent("processed.mp4")
        try "PROCESSED".data(using: .utf8)!.write(to: processedVideo)

        let track = try bundle.appendPolishGeneration(
            trackID: "host",
            audioWAVSource: cleaned,
            videoSource: processedVideo
        )

        // Both chains advanced to generation 002, in lockstep.
        #expect(track.current == "intermediate/host/002_polish.wav")
        #expect(track.videoCurrent == "intermediate/host/002_polish.mp4")
        #expect(track.history == ["intermediate/host/001_import.wav", "intermediate/host/002_polish.wav"])
        #expect(track.videoHistory == ["sources/host.mp4", "intermediate/host/002_polish.mp4"])

        let fm = FileManager.default
        let root = workspace.appendingPathComponent("ep01.maycast")
        #expect(fm.fileExists(atPath: root.appendingPathComponent("intermediate/host/002_polish.wav").path))
        #expect(fm.fileExists(atPath: root.appendingPathComponent("intermediate/host/002_polish.mp4").path))
        // The audio generation reflects the cleaned length.
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
        let processedVideo = workspace.appendingPathComponent("processed.mp4")
        try "PROCESSED".data(using: .utf8)!.write(to: processedVideo)

        _ = try bundle.appendPolishGeneration(trackID: "host", audioWAVSource: cleaned, videoSource: processedVideo)
        _ = try bundle.undo()

        let track = bundle.track(withID: "host")!
        #expect(track.current == "intermediate/host/001_import.wav")
        #expect(track.videoCurrent == "sources/host.mp4")
    }

    @Test
    func polishAudioOnlyTrackLeavesVideoChainAbsent() throws {
        let workspace = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: workspace) }
        var bundle = try makeEpisode(at: workspace, video: false)

        let cleaned = workspace.appendingPathComponent("cleaned.wav")
        try AudioIO.writeWAV(AudioIO.silence(duration: 1.5, sampleRate: 48000, channelCount: 1), to: cleaned)

        let track = try bundle.appendPolishGeneration(trackID: "host", audioWAVSource: cleaned, videoSource: nil)
        #expect(track.current == "intermediate/host/002_polish.wav")
        #expect(track.videoCurrent == nil)
        #expect(track.videoHistory == nil)
    }
}

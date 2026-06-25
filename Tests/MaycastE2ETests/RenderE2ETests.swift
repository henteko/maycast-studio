import Testing
import Foundation
import MaycastCore

@Suite("maycast render / video import")
struct RenderE2ETests {
    /// Importing a video extracts its audio as the first generation and keeps
    /// the video as the track's immutable video source.
    @Test
    func importVideoExtractsAudioAndKeepsVideo() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }

        let episodePath = workspace.appendingPathComponent("ep01.maycast")
        _ = try harness.run(["init", episodePath.path])

        let hostVideo = workspace.appendingPathComponent("host-cam.mp4")
        try harness.writeTestVideo(at: hostVideo, duration: 1.0)

        let result = try harness.run([
            "import", "-project", episodePath.path, "--as", "host", hostVideo.path,
        ])
        #expect(result.succeeded, "stderr: \(result.stderr)\nstdout: \(result.stdout)")

        let fm = FileManager.default
        // Video kept as source; audio extracted into the first generation.
        #expect(fm.fileExists(atPath: episodePath.appendingPathComponent("sources/host.mp4").path))
        let firstGen = episodePath.appendingPathComponent("intermediate/host/001_import.wav")
        #expect(fm.fileExists(atPath: firstGen.path))
        let buffer = try AudioIO.read(from: firstGen)
        #expect(abs(buffer.duration - 1.0) < 0.1)

        // episode.json carries the video source + an identity cumulative edit.
        let json = try Data(contentsOf: episodePath.appendingPathComponent("episode.json"))
        let decoded = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        let track = (decoded?["tracks"] as? [[String: Any]])?.first
        #expect(track?["videoSource"] as? String == "sources/host.mp4")
        let videoEdit = track?["videoEdit"] as? [String: Any]
        #expect((videoEdit?["clips"] as? [[String: Any]])?.count == 1)
        #expect((track?["videoEditHistory"] as? [[String: Any]])?.count == 1)
    }

    /// Audio import leaves the video pointers absent (audio-only track).
    @Test
    func importAudioHasNoVideoPointers() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }

        let episodePath = workspace.appendingPathComponent("ep01.maycast")
        _ = try harness.run(["init", episodePath.path])
        let host = workspace.appendingPathComponent("host.wav")
        try harness.writeSilentWAV(at: host, duration: 0.5)
        _ = try harness.run(["import", "-project", episodePath.path, "--as", "host", host.path])

        let json = try Data(contentsOf: episodePath.appendingPathComponent("episode.json"))
        let decoded = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        let track = (decoded?["tracks"] as? [[String: Any]])?.first
        #expect(track?["videoSource"] == nil)
        #expect(track?["videoEdit"] == nil)
    }

    /// `render` produces one mp4 per video speaker, each carrying the chapters.
    /// (Audio mp3 is the separate `mix` command.)
    @Test
    func renderProducesPerSpeakerMp4WithChapters() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }

        let episodePath = workspace.appendingPathComponent("ep01.maycast")
        _ = try harness.run(["init", episodePath.path])

        for (id, freq) in [("host", 220.0), ("guest", 440.0)] {
            let video = workspace.appendingPathComponent("\(id).mp4")
            try harness.writeTestVideo(at: video, duration: 2.0, frequency: freq)
            _ = try harness.run(["import", "-project", episodePath.path, "--as", id, video.path])
        }

        // A chapter on the voice timeline.
        _ = try harness.run(["chapter", "add", "-project", episodePath.path,
                             "--at", "0.5", "--title", "Intro talk"])

        let result = try harness.run(["render", "-project", episodePath.path])
        #expect(result.succeeded, "stderr: \(result.stderr)\nstdout: \(result.stdout)")

        let fm = FileManager.default
        let hostMp4 = episodePath.appendingPathComponent("exports/host.mp4")
        let guestMp4 = episodePath.appendingPathComponent("exports/guest.mp4")
        #expect(fm.fileExists(atPath: hostMp4.path))
        #expect(fm.fileExists(atPath: guestMp4.path))
        // render is video-only — it does not produce the mp3.
        #expect(!fm.fileExists(atPath: episodePath.appendingPathComponent("exports/ep01.mp3").path))

        // The mp4 must actually contain a video + audio stream...
        let streams = harness.ffprobe([
            "-v", "error", "-show_entries", "stream=codec_type",
            "-of", "default=nw=1", hostMp4.path,
        ])
        #expect(streams.contains("codec_type=video"))
        #expect(streams.contains("codec_type=audio"))

        // ...and the chapter must have round-tripped into the container.
        let chapters = harness.ffprobe([
            "-v", "error", "-show_chapters", "-of", "default=nw=1", hostMp4.path,
        ])
        #expect(chapters.contains("Intro talk"))
    }

    /// `render` on an audio-only episode fails (there's no video to render).
    @Test
    func renderAudioOnlyEpisodeFails() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }

        let episodePath = workspace.appendingPathComponent("ep01.maycast")
        _ = try harness.run(["init", episodePath.path])
        let host = workspace.appendingPathComponent("host.wav")
        try harness.writeSilentWAV(at: host, duration: 1.0)
        _ = try harness.run(["import", "-project", episodePath.path, "--as", "host", host.path])

        let result = try harness.run(["render", "-project", episodePath.path])
        #expect(!result.succeeded)

        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: episodePath.appendingPathComponent("exports/host.mp4").path))
    }
}

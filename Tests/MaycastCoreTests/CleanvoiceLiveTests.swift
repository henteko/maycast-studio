import Testing
import Foundation
@testable import MaycastCore

/// Opt-in round-trips against the real Cleanvoice API (consumes credits).
/// Skipped unless `CLEANVOICE_LIVE_API_KEY` is set:
///
///     CLEANVOICE_LIVE_API_KEY=cvk_... swift test --filter CleanvoiceLive
///
/// Input audio is synthesized with `say`, so it also needs macOS TTS.
@Suite("Cleanvoice live API", .serialized, .enabled(if: ProcessInfo.processInfo.environment["CLEANVOICE_LIVE_API_KEY"] != nil))
struct CleanvoiceLiveTests {
    private var apiKey: String { ProcessInfo.processInfo.environment["CLEANVOICE_LIVE_API_KEY"] ?? "" }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("maycast-cleanvoice-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Speak `text` into a 48 kHz mono WAV at `url` (via `say` + `afconvert`).
    private func speak(_ text: String, voice: String, to url: URL) throws {
        let aiff = url.deletingPathExtension().appendingPathExtension("aiff")
        try run("/usr/bin/say", ["-v", voice, "-o", aiff.path, text])
        try run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@48000", "-c", "1", aiff.path, url.path])
    }

    private func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0, "\(tool) failed")
    }

    private func makeEpisode(at workspace: URL, speech: [(id: String, voice: String, text: String)], video: Bool = false) throws -> URL {
        let episodeURL = workspace.appendingPathComponent("ep01.maycast")
        var bundle = try EpisodeBundle.create(at: episodeURL)
        for s in speech {
            let rel = "intermediate/\(s.id)/001_import.wav"
            let url = episodeURL.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try speak(s.text, voice: s.voice, to: url)
            // The engine never reads the video itself — only the track's
            // video edit — so a placeholder source is enough.
            let duration = try AudioIO.probeDuration(of: url)
            let identity = Arrangement.single(sourceDuration: duration)
            bundle.upsertTrack(Track(
                id: s.id,
                source: video ? "sources/\(s.id).mp4" : "sources/\(s.id).wav",
                current: rel,
                history: [rel],
                videoSource: video ? "sources/\(s.id).mp4" : nil,
                videoEdit: video ? identity : nil,
                videoEditHistory: video ? [identity] : nil
            ))
        }
        try bundle.save()
        return episodeURL
    }

    private func runEngine(_ episode: URL, ids: [String], options: CleanvoicePolishOptions = .defaults) async throws -> [PolishTrackOutput] {
        let engine = CleanvoicePolishEngine(apiKey: apiKey, options: options, pollInitialDelay: 5, pollInterval: 5)
        return try await engine.run(
            bundleURL: episode,
            speakers: ids.map { PolishSpeaker(id: $0, fileURL: episode.appendingPathComponent("intermediate/\($0)/001_import.wav")) }
        ) { p in print("[cleanvoice-live] \(p)") }
    }

    @Test
    func multitrackRoundTrip() async throws {
        let workspace = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let episode = try makeEpisode(at: workspace, speech: [
            ("host", "Samantha", "Um, hello and welcome to the show. Uh, today we are, um, talking about podcasts. [[slnc 4000]] So, uh, let's wrap up."),
            ("guest", "Daniel", "[[slnc 5000]] Thanks for having me. Uh, I really like podcasts. [[slnc 4000]] Um, yes."),
        ])

        let outputs = try await runEngine(episode, ids: ["host", "guest"])
        #expect(outputs.map(\.generationPath) == ["intermediate/host/002_polish.wav", "intermediate/guest/002_polish.wav"])
        for id in ["host", "guest"] {
            let before = try AudioIO.probeDuration(of: episode.appendingPathComponent("intermediate/\(id)/001_import.wav"))
            let after = try AudioIO.probeDuration(of: episode.appendingPathComponent("intermediate/\(id)/002_polish.wav"))
            print("[cleanvoice-live] \(id): \(before)s → \(after)s")
            #expect(after > 0)
        }
    }

    @Test
    func singleTrackWithLongSilenceIsCut() async throws {
        let workspace = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let episode = try makeEpisode(at: workspace, speech: [
            ("host", "Samantha", "Hello and welcome to the show. Today we are talking about podcasts. [[slnc 8000]] That was a long pause. Let's wrap up now."),
        ])
        let before = try AudioIO.probeDuration(of: episode.appendingPathComponent("intermediate/host/001_import.wav"))

        let outputs = try await runEngine(episode, ids: ["host"])
        #expect(outputs.map(\.generationPath) == ["intermediate/host/002_polish.wav"])
        let after = try AudioIO.probeDuration(of: episode.appendingPathComponent("intermediate/host/002_polish.wav"))
        print("[cleanvoice-live] host: \(before)s → \(after)s")
        #expect(after < before - 2, "long silence should have been cut")
    }

    /// Video tracks: cuts are replayed from Cleanvoice's cut list, and every
    /// track's picture must end up exactly as long as its cleaned audio.
    @Test
    func multitrackVideoFollowsCuts() async throws {
        let workspace = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let episode = try makeEpisode(at: workspace, speech: [
            ("host", "Samantha", "Um, hello and welcome to the show. Uh, today we are, um, talking about, uh, podcasts. [[slnc 6000]] So, uh, um, let's, let's wrap up."),
            ("guest", "Daniel", "[[slnc 9000]] Thanks for having me. [[slnc 7000]] Um, yes, uh, bye."),
        ], video: true)

        _ = try await runEngine(episode, ids: ["host", "guest"])
        let bundle = try EpisodeBundle.open(at: episode)
        for id in ["host", "guest"] {
            let before = try AudioIO.probeDuration(of: episode.appendingPathComponent("intermediate/\(id)/001_import.wav"))
            let audio = try AudioIO.probeDuration(of: episode.appendingPathComponent("intermediate/\(id)/002_polish.wav"))
            let edit = try #require(bundle.track(withID: id)?.videoEdit)
            print("[cleanvoice-live] \(id): \(before)s → audio \(audio)s, video \(edit.totalDuration)s, kept \(edit.clips.map { "\($0.sourceStart)–\($0.sourceEnd)" })")
            #expect(audio < before - 1, "the long silence should have been cut")
            #expect(abs(edit.totalDuration - audio) < 0.005, "picture must match the cleaned audio")
        }
    }

    /// The video-episode path relies on `muted` keeping the original length.
    @Test
    func mutedEditsKeepLength() async throws {
        let workspace = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let episode = try makeEpisode(at: workspace, speech: [
            ("host", "Samantha", "Hello and welcome to the show. Today we are talking about podcasts. [[slnc 8000]] That was a long pause. Let's wrap up now."),
        ])
        let before = try AudioIO.probeDuration(of: episode.appendingPathComponent("intermediate/host/001_import.wav"))

        var options = CleanvoicePolishOptions.defaults
        options.muteEdits = true
        _ = try await runEngine(episode, ids: ["host"], options: options)
        let after = try AudioIO.probeDuration(of: episode.appendingPathComponent("intermediate/host/002_polish.wav"))
        print("[cleanvoice-live] host (muted): \(before)s → \(after)s")
        #expect(abs(after - before) < 0.05, "muted edits must not change the length")
    }
}

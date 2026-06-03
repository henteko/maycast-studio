import Testing
import Foundation
import MaycastCore

/// E2E tests for the chapter feature (docs/chapters.md).
///
/// Chapters are episode-level metadata stored in `episode.json` under
/// `chapters[]`, generated from the transcript by Google Gemini and embedded
/// into the final MP3 as ID3v2 chapter frames (CHAP/CTOC) by `mix`.
///
/// Generation can't reach the network in CI, so these tests drive the
/// deterministic stub engine selected with `MAYCAST_CHAPTER_ENGINE=fake`. The
/// stub derives one chapter per transcript segment, exercising the full
/// CLI → XPC → episode.json plumbing without a Gemini call. The Gemini engine
/// itself is unit-tested with a stubbed URLSession in `GeminiChapterEngineTests`.
@Suite("chapters")
struct ChapterE2ETests {

    // MARK: - Helpers

    /// `init` an episode and import a single voice track of the given duration.
    private func setupEpisodeWithHost(
        harness: E2EHarness,
        workspace: URL,
        hostDuration: Double = 2.0
    ) throws -> URL {
        let episode = workspace.appendingPathComponent("ep01.maycast")
        _ = try harness.run(["init", episode.path])
        let host = workspace.appendingPathComponent("host.wav")
        try harness.writeSineWaveWAV(at: host, frequency: 333, duration: hostDuration)
        _ = try harness.run(["import", "-project", episode.path, "--as", "host", host.path])
        return episode
    }

    /// Read the `chapters[]` array straight out of episode.json. Parsing the
    /// manifest directly (rather than the Core model) keeps the test resilient
    /// to model-shape churn — matching MixIntroOutroE2ETests.
    private func readChapters(_ episode: URL) throws -> [[String: Any]] {
        let url = episode.appendingPathComponent("episode.json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        return (json["chapters"] as? [[String: Any]]) ?? []
    }

    /// Overwrite the current transcript sidecar for a track with explicit
    /// segments, so the fake generation engine has deterministic input.
    private func writeTranscript(
        episode: URL,
        trackID: String,
        segments: [(start: Double, end: Double, text: String)]
    ) throws {
        // Locate the track's current generation from episode.json and write
        // the matching `.transcript.json` sidecar next to it.
        let manifestURL = episode.appendingPathComponent("episode.json")
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
        let tracks = manifest["tracks"] as! [[String: Any]]
        let track = tracks.first { $0["id"] as? String == trackID }!
        let current = track["current"] as! String           // e.g. intermediate/host/001_import.wav
        let transcriptRel = (current as NSString).deletingPathExtension + ".transcript.json"
        let transcriptURL = episode.appendingPathComponent(transcriptRel)

        let payload: [String: Any] = [
            "segments": segments.map { ["start": $0.start, "end": $0.end, "text": $0.text] }
        ]
        try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
            .write(to: transcriptURL)
    }

    // MARK: - Manual editing (no LLM)

    @Test
    func addAndListChapters() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }
        let episode = try setupEpisodeWithHost(harness: harness, workspace: workspace)

        var result = try harness.run([
            "chapter", "add", "-project", episode.path, "--at", "0", "--title", "Opening",
        ])
        #expect(result.succeeded, "stderr: \(result.stderr)")

        result = try harness.run([
            "chapter", "add", "-project", episode.path, "--at", "92.4", "--title", "Main topic",
        ])
        #expect(result.succeeded, "stderr: \(result.stderr)")

        let chapters = try readChapters(episode)
        #expect(chapters.count == 2)
        #expect(chapters.contains { $0["title"] as? String == "Opening" })
        #expect(chapters.contains { $0["title"] as? String == "Main topic" })

        let list = try harness.run(["chapter", "list", "-project", episode.path])
        #expect(list.succeeded, "stderr: \(list.stderr)")
        #expect(list.stdout.contains("Opening"))
        #expect(list.stdout.contains("Main topic"))
    }

    @Test
    func editChapter() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }
        let episode = try setupEpisodeWithHost(harness: harness, workspace: workspace)

        _ = try harness.run(["chapter", "add", "-project", episode.path, "--at", "10", "--title", "Draft"])
        let id = (try readChapters(episode)).first!["id"] as! String

        let result = try harness.run([
            "chapter", "edit", "-project", episode.path, "--id", id,
            "--at", "12.5", "--title", "Renamed",
        ])
        #expect(result.succeeded, "stderr: \(result.stderr)")

        let chapters = try readChapters(episode)
        #expect(chapters.count == 1)
        #expect(chapters[0]["title"] as? String == "Renamed")
        #expect((chapters[0]["start"] as? Double) == 12.5)
    }

    @Test
    func removeChapter() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }
        let episode = try setupEpisodeWithHost(harness: harness, workspace: workspace)

        _ = try harness.run(["chapter", "add", "-project", episode.path, "--at", "0", "--title", "Keep"])
        _ = try harness.run(["chapter", "add", "-project", episode.path, "--at", "30", "--title", "Drop"])
        let dropID = (try readChapters(episode)).first { $0["title"] as? String == "Drop" }!["id"] as! String

        let result = try harness.run(["chapter", "remove", "-project", episode.path, "--id", dropID])
        #expect(result.succeeded, "stderr: \(result.stderr)")

        let chapters = try readChapters(episode)
        #expect(chapters.count == 1)
        #expect(chapters[0]["title"] as? String == "Keep")
    }

    @Test
    func applyChaptersFromFile() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }
        let episode = try setupEpisodeWithHost(harness: harness, workspace: workspace)

        let chaptersFile = workspace.appendingPathComponent("chapters.json")
        let payload: [[String: Any]] = [
            ["start": 0.0, "title": "Intro", "source": "manual"],
            ["start": 45.0, "title": "Body", "source": "manual"],
            ["start": 120.0, "title": "Outro", "source": "manual"],
        ]
        try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
            .write(to: chaptersFile)

        let result = try harness.run([
            "chapter", "apply", "-project", episode.path, "--file", chaptersFile.path,
        ])
        #expect(result.succeeded, "stderr: \(result.stderr)")

        let chapters = try readChapters(episode)
        #expect(chapters.count == 3)
        #expect(chapters.map { $0["title"] as? String } == ["Intro", "Body", "Outro"])
    }

    // MARK: - Generation (stub engine)

    @Test
    func generateChaptersWithFakeEngine() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }
        let episode = try setupEpisodeWithHost(harness: harness, workspace: workspace)

        try writeTranscript(episode: episode, trackID: "host", segments: [
            (0.0, 5.0, "今日はポッドキャストの編集について話します"),
            (60.0, 65.0, "次にチャプター機能の紹介です"),
            (120.0, 125.0, "最後にまとめとお知らせ"),
        ])

        let result = try harness.run(
            ["chapter", "generate", "-project", episode.path],
            extraEnvironment: ["MAYCAST_CHAPTER_ENGINE": "fake"]
        )
        #expect(result.succeeded, "stderr: \(result.stderr)")

        let chapters = try readChapters(episode)
        // The stub derives at least one chapter from the transcript segments.
        #expect(chapters.count >= 1)
        // Chapters are stored sorted by start time, all within episode bounds.
        let starts = chapters.compactMap { $0["start"] as? Double }
        #expect(starts == starts.sorted())
        #expect(chapters.allSatisfy { ($0["source"] as? String) == "generated" })
    }

    /// The default (Gemini) engine must never hard-fail when no API key is
    /// available: it falls back to the heuristic engine so chapter generation
    /// always produces something. We run with an empty `GEMINI_API_KEY` so the
    /// network is never touched.
    @Test
    func generateChaptersFallsBackWhenGeminiKeyMissing() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }
        let episode = try setupEpisodeWithHost(harness: harness, workspace: workspace)

        try writeTranscript(episode: episode, trackID: "host", segments: [
            (0.0, 5.0, "今日はポッドキャストの編集について話します"),
            (60.0, 65.0, "次にチャプター機能の紹介です"),
            (120.0, 125.0, "最後にまとめとお知らせ"),
        ])

        // engine=gemini (default) + no key → heuristic fallback, exit 0.
        let result = try harness.run(
            ["chapter", "generate", "-project", episode.path, "--engine", "gemini"],
            extraEnvironment: ["GEMINI_API_KEY": ""]
        )
        #expect(result.succeeded, "stderr: \(result.stderr)")
        #expect(result.stdout.contains("heuristic fallback"),
                "expected a heuristic-fallback note, got: \(result.stdout)")

        let chapters = try readChapters(episode)
        #expect(chapters.count >= 1)
        #expect(chapters.allSatisfy { ($0["source"] as? String) == "generated" })
    }

    // MARK: - Mix embedding (MP3 / ID3v2 chapters)

    /// Read chapter titles (in order) from a media file via `ffprobe`. The MP3
    /// muxer in ffmpeg writes ID3v2 CHAP/CTOC frames; ffprobe is the same
    /// toolchain that wrote them, so this verifies the on-disk frames rather
    /// than trusting a re-read of our own intermediate state. `ffprobe` is
    /// resolved on PATH (it ships alongside `ffmpeg`).
    private func ffprobeChapterTitles(_ url: URL) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "ffprobe", "-v", "quiet", "-print_format", "json", "-show_chapters", url.path,
        ]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let chapters = json["chapters"] as? [[String: Any]]
        else { return [] }
        return chapters.compactMap { ($0["tags"] as? [String: Any])?["title"] as? String }
    }

    @Test
    func mixEmbedsChaptersIntoMP3() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }
        let episode = try setupEpisodeWithHost(harness: harness, workspace: workspace, hostDuration: 2.0)

        _ = try harness.run(["chapter", "add", "-project", episode.path, "--at", "0", "--title", "Opening"])
        _ = try harness.run(["chapter", "add", "-project", episode.path, "--at", "1.0", "--title", "メイン"])

        let result = try harness.run([
            "mix", "-project", episode.path, "--output", "exports/ep01.mp3",
        ])
        #expect(result.succeeded, "stderr: \(result.stderr)")

        let outputURL = episode.appendingPathComponent("exports/ep01.mp3")
        #expect(FileManager.default.fileExists(atPath: outputURL.path))

        // The embedded ID3v2 chapters should round-trip with the same titles.
        // With no intro/outro the voice-timeline starts map 1:1 onto the final
        // timeline (docs/chapters.md §6). A UTF-8 title (メイン) confirms the
        // ffmetadata escaping / encoding survives the round-trip.
        let titles = try ffprobeChapterTitles(outputURL)
        #expect(titles.count == 2, "expected 2 chapters, got \(titles)")
        #expect(titles.contains("Opening"))
        #expect(titles.contains("メイン"))
    }

    @Test
    func mixDefaultOutputIsMP3() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }
        let episode = try setupEpisodeWithHost(harness: harness, workspace: workspace)

        let result = try harness.run(["mix", "-project", episode.path])
        #expect(result.succeeded, "stderr: \(result.stderr)")

        // Default export path is exports/{episodeID}.mp3 (chapter-friendly for
        // Android clients that don't read m4a chapter tracks).
        let outputURL = episode.appendingPathComponent("exports/ep01.mp3")
        #expect(FileManager.default.fileExists(atPath: outputURL.path),
                "expected default mix output at exports/ep01.mp3")
    }
}


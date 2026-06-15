import Testing
import Foundation
import MaycastCore

/// E2E tests for the edit-cue feature.
///
/// Edit cues are episode-level metadata stored in `episode.json` under
/// `editCues[]`. They flag transcript utterances where a host verbally asks for
/// an edit ("ここカットで", "今の言い直す", …) so the slice editor can highlight
/// cut points. Detection normally runs on Google Gemini; since CI can't reach
/// the network, these tests drive the deterministic stub engine selected with
/// `MAYCAST_EDITCUE_ENGINE=fake`, which flags any transcript segment containing
/// an editing keyword. This exercises the full CLI → XPC → episode.json
/// plumbing without a Gemini call.
@Suite("editcue")
struct EditCueE2ETests {

    // MARK: - Helpers

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

    private func readEditCues(_ episode: URL) throws -> [[String: Any]] {
        let url = episode.appendingPathComponent("episode.json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        return (json["editCues"] as? [[String: Any]]) ?? []
    }

    private func writeTranscript(
        episode: URL,
        trackID: String,
        segments: [(start: Double, end: Double, text: String)]
    ) throws {
        let manifestURL = episode.appendingPathComponent("episode.json")
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
        let tracks = manifest["tracks"] as! [[String: Any]]
        let track = tracks.first { $0["id"] as? String == trackID }!
        let current = track["current"] as! String
        let transcriptRel = (current as NSString).deletingPathExtension + ".transcript.json"
        let transcriptURL = episode.appendingPathComponent(transcriptRel)
        let payload: [String: Any] = [
            "segments": segments.map { ["start": $0.start, "end": $0.end, "text": $0.text] }
        ]
        try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
            .write(to: transcriptURL)
    }

    // MARK: - Generation (stub engine)

    @Test
    func detectsEditInstructionsAndSkipsNormalSpeech() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }
        let episode = try setupEpisodeWithHost(harness: harness, workspace: workspace)

        try writeTranscript(episode: episode, trackID: "host", segments: [
            (0.0, 2.0, "じゃあ今日のテーマ始めましょうか。"),               // normal
            (2.2, 5.0, "あ、ごめん今の噛んだんでここカットでお願いします。"),   // cut
            (5.4, 8.0, "改めまして、本題のエンジンXについて話します。"),        // normal
            (8.4, 11.0, "さっきの説明違ったんでもう一回言い直しますね。"),       // retake
            (11.4, 14.0, "C10K問題というのがありまして面白いんですよ。"),       // normal
            (14.4, 17.0, "この長い余談は後で飛ばしておいてください。"),          // skip
        ])

        let result = try harness.run(
            ["editcue", "generate", "-project", episode.path],
            extraEnvironment: ["MAYCAST_EDITCUE_ENGINE": "fake"]
        )
        #expect(result.succeeded, "stderr: \(result.stderr)")

        let cues = try readEditCues(episode)
        // Exactly the three edit-instruction segments are flagged.
        #expect(cues.count == 3, "expected 3 cues, got \(cues.count): \(cues)")

        // Stored sorted by start, within episode bounds.
        let starts = cues.compactMap { $0["start"] as? Double }
        #expect(starts == starts.sorted())

        let kindsByStart = Dictionary(uniqueKeysWithValues: cues.compactMap { cue -> (Double, String)? in
            guard let s = cue["start"] as? Double, let k = cue["kind"] as? String else { return nil }
            return (s, k)
        })
        #expect(kindsByStart[2.2] == "cut")
        #expect(kindsByStart[8.4] == "retake")
        #expect(kindsByStart[14.4] == "skip")
    }

    @Test
    func listPrintsFlaggedCues() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }
        let episode = try setupEpisodeWithHost(harness: harness, workspace: workspace)

        try writeTranscript(episode: episode, trackID: "host", segments: [
            (0.0, 2.0, "通常の会話です。"),
            (2.2, 5.0, "ここカットでお願いします。"),
        ])

        _ = try harness.run(
            ["editcue", "generate", "-project", episode.path],
            extraEnvironment: ["MAYCAST_EDITCUE_ENGINE": "fake"]
        )

        let list = try harness.run(["editcue", "list", "-project", episode.path])
        #expect(list.succeeded, "stderr: \(list.stderr)")
        #expect(list.stdout.contains("cut"))
        #expect(list.stdout.contains("カット"))
    }

    @Test
    func clearRemovesAllCues() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }
        let episode = try setupEpisodeWithHost(harness: harness, workspace: workspace)

        try writeTranscript(episode: episode, trackID: "host", segments: [
            (2.2, 5.0, "ここカットでお願いします。"),
        ])
        _ = try harness.run(
            ["editcue", "generate", "-project", episode.path],
            extraEnvironment: ["MAYCAST_EDITCUE_ENGINE": "fake"]
        )
        #expect(try readEditCues(episode).count == 1)

        let result = try harness.run(["editcue", "clear", "-project", episode.path])
        #expect(result.succeeded, "stderr: \(result.stderr)")
        #expect(try readEditCues(episode).isEmpty)
    }

    /// Unlike chapters, edit-cue detection is Gemini-only: there is no heuristic
    /// fallback. With no API key the default engine must fail clearly rather than
    /// silently produce nothing, so the user knows detection didn't run.
    @Test
    func geminiEngineFailsWhenKeyMissing() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }
        let episode = try setupEpisodeWithHost(harness: harness, workspace: workspace)

        try writeTranscript(episode: episode, trackID: "host", segments: [
            (2.2, 5.0, "ここカットでお願いします。"),
        ])

        let result = try harness.run(
            ["editcue", "generate", "-project", episode.path, "--engine", "gemini"],
            extraEnvironment: ["GEMINI_API_KEY": ""]
        )
        #expect(!result.succeeded, "expected failure with no API key, stdout: \(result.stdout)")
    }
}

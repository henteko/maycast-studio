import Testing
import Foundation

@Suite("maycast show")
struct ShowE2ETests {
    @Test
    func showInitCreatesBundle() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }

        let showPath = workspace.appendingPathComponent("my-podcast.maycastshow")
        let result = try harness.run(["show", "init", showPath.path])
        #expect(result.succeeded, "stderr: \(result.stderr)\nstdout: \(result.stdout)")

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: showPath.path))
        #expect(fm.fileExists(atPath: showPath.appendingPathComponent("show.json").path))
        #expect(fm.fileExists(atPath: showPath.appendingPathComponent("assets").path))
        #expect(fm.fileExists(atPath: showPath.appendingPathComponent("episodes").path))
    }

    @Test
    func showSetAssetCopiesIntroOutroBgm() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }

        let intro = workspace.appendingPathComponent("intro.mp3")
        let outro = workspace.appendingPathComponent("outro.mp3")
        let bgm = workspace.appendingPathComponent("bgm.mp3")
        try harness.writeDummyAudio(at: intro, content: "INTRO")
        try harness.writeDummyAudio(at: outro, content: "OUTRO")
        try harness.writeDummyAudio(at: bgm, content: "BGM")

        let showPath = workspace.appendingPathComponent("show.maycastshow")
        _ = try harness.run(["show", "init", showPath.path])

        let result = try harness.run([
            "show", "set-asset",
            "-show", showPath.path,
            "--intro", intro.path,
            "--outro", outro.path,
            "--bgm", bgm.path,
        ])
        #expect(result.succeeded, "stderr: \(result.stderr)")

        let assets = showPath.appendingPathComponent("assets")
        #expect(FileManager.default.fileExists(atPath: assets.appendingPathComponent("intro.mp3").path))
        #expect(FileManager.default.fileExists(atPath: assets.appendingPathComponent("outro.mp3").path))
        #expect(FileManager.default.fileExists(atPath: assets.appendingPathComponent("bgm.mp3").path))
    }

    @Test
    func initWithShowSnapshotsAssets() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }

        let intro = workspace.appendingPathComponent("intro.mp3")
        try harness.writeDummyAudio(at: intro, content: "INTRO-CONTENT")

        let showPath = workspace.appendingPathComponent("show.maycastshow")
        _ = try harness.run(["show", "init", showPath.path])
        _ = try harness.run(["show", "set-asset", "-show", showPath.path, "--intro", intro.path])

        let episodePath = showPath.appendingPathComponent("episodes/ep01.maycast")
        let result = try harness.run(["init", episodePath.path, "-show", showPath.path])
        #expect(result.succeeded, "stderr: \(result.stderr)")

        let copiedIntro = episodePath.appendingPathComponent("assets/intro.mp3")
        #expect(FileManager.default.fileExists(atPath: copiedIntro.path))
        let body = try String(contentsOf: copiedIntro, encoding: .utf8)
        #expect(body == "INTRO-CONTENT")

        let json = try Data(contentsOf: episodePath.appendingPathComponent("episode.json"))
        let decoded = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        let mix = decoded?["mix"] as? [String: Any]
        #expect(mix?["intro"] as? String == "assets/intro.mp3")
        #expect(decoded?["show"] is String)
    }
}

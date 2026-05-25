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
    func showListEnumeratesBundlesByName() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }

        let library = workspace.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)

        let alpha = library.appendingPathComponent("alpha.maycastshow")
        let zeta = library.appendingPathComponent("zeta.maycastshow")
        _ = try harness.run(["show", "init", alpha.path, "-name", "Alpha Show"])
        _ = try harness.run(["show", "init", zeta.path, "-name", "Zeta Show"])

        // Non-show entries in the directory must be ignored.
        try harness.writeDummyAudio(at: library.appendingPathComponent("notes.txt"), content: "x")

        let result = try harness.run(["show", "list", "-in", library.path])
        #expect(result.succeeded, "stderr: \(result.stderr)\nstdout: \(result.stdout)")
        #expect(result.stdout.contains("Found 2 show(s)"))
        #expect(result.stdout.contains("Alpha Show"))
        #expect(result.stdout.contains("Zeta Show"))
        #expect(result.stdout.contains(alpha.path))
        #expect(result.stdout.contains(zeta.path))

        // Output is sorted case-insensitively by display name.
        guard let alphaIdx = result.stdout.range(of: "Alpha Show")?.lowerBound,
              let zetaIdx = result.stdout.range(of: "Zeta Show")?.lowerBound else {
            Issue.record("Both shows should appear in output")
            return
        }
        #expect(alphaIdx < zetaIdx)
    }

    @Test
    func showListEmptyDirectoryReturnsNoShows() throws {
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }

        let result = try harness.run(["show", "list", "-in", workspace.path])
        #expect(result.succeeded, "stderr: \(result.stderr)")
        #expect(result.stdout.contains("Found 0 show(s)"))
    }

    @Test
    func initWithShowInSiblingDirectorySnapshotsAssets() throws {
        // Mirrors the GUI library layout: Shows/ and Episodes/ are siblings, so
        // the episode→show reference is a "../../Shows/..." relative path. The
        // contract we guard: assets snapshot-copy correctly across sibling dirs
        // (the copy uses the show's absolute URL), and the reference points at
        // the right show bundle.
        let harness = E2EHarness()
        let workspace = try harness.makeTempWorkspace()
        defer { harness.cleanup(workspace) }

        let shows = workspace.appendingPathComponent("Shows")
        let episodes = workspace.appendingPathComponent("Episodes")
        try FileManager.default.createDirectory(at: shows, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: episodes, withIntermediateDirectories: true)

        let intro = workspace.appendingPathComponent("intro.mp3")
        try harness.writeDummyAudio(at: intro, content: "INTRO-SIBLING")

        let showPath = shows.appendingPathComponent("my-show.maycastshow")
        _ = try harness.run(["show", "init", showPath.path, "-name", "My Show"])
        _ = try harness.run(["show", "set-asset", "-show", showPath.path, "--intro", intro.path])

        let episodePath = episodes.appendingPathComponent("ep01.maycast")
        let result = try harness.run(["init", episodePath.path, "-show", showPath.path])
        #expect(result.succeeded, "stderr: \(result.stderr)")

        // Assets are snapshot-copied into the sibling episode.
        let copiedIntro = episodePath.appendingPathComponent("assets/intro.mp3")
        #expect(FileManager.default.fileExists(atPath: copiedIntro.path))
        #expect(try String(contentsOf: copiedIntro, encoding: .utf8) == "INTRO-SIBLING")

        // The stored relative show reference points at the right show bundle.
        let json = try Data(contentsOf: episodePath.appendingPathComponent("episode.json"))
        let decoded = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        guard let showRel = decoded?["show"] as? String else {
            Issue.record("episode.json should carry a 'show' reference")
            return
        }
        #expect(showRel.hasSuffix("Shows/my-show.maycastshow"))
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

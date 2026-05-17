import Testing
import Foundation
@testable import MaycastCore

// MARK: - Helpers

private func makeTempDir() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("maycast-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writeDummyFile(at url: URL, content: String = "dummy") throws {
    try content.data(using: .utf8)!.write(to: url, options: .atomic)
}

// MARK: - ShowBundle

@Test
func showBundleCreateAndOpenRoundTrip() throws {
    let workspace = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: workspace) }

    let showURL = workspace.appendingPathComponent("my-podcast.maycastshow")
    let created = try ShowBundle.create(at: showURL)
    #expect(created.show.name == "my-podcast")
    #expect(FileManager.default.fileExists(atPath: created.manifestURL.path))
    #expect(FileManager.default.fileExists(atPath: created.assetsDirectoryURL.path))
    #expect(FileManager.default.fileExists(atPath: created.episodesDirectoryURL.path))

    let opened = try ShowBundle.open(at: showURL)
    #expect(opened.show.uuid == created.show.uuid)
}

@Test
func showSetAssetsCopiesFiles() throws {
    let workspace = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: workspace) }

    let intro = workspace.appendingPathComponent("intro.mp3")
    let outro = workspace.appendingPathComponent("outro.mp3")
    let bgm = workspace.appendingPathComponent("bgm.mp3")
    try writeDummyFile(at: intro)
    try writeDummyFile(at: outro)
    try writeDummyFile(at: bgm)

    let showURL = workspace.appendingPathComponent("show.maycastshow")
    var show = try ShowBundle.create(at: showURL)
    try show.setAssets(intro: intro, outro: outro, bgm: bgm)

    #expect(FileManager.default.fileExists(atPath: show.assetsDirectoryURL.appendingPathComponent("intro.mp3").path))
    #expect(FileManager.default.fileExists(atPath: show.assetsDirectoryURL.appendingPathComponent("outro.mp3").path))
    #expect(FileManager.default.fileExists(atPath: show.assetsDirectoryURL.appendingPathComponent("bgm.mp3").path))

    let opened = try ShowBundle.open(at: showURL)
    #expect(opened.show.assets.intro == "assets/intro.mp3")
    #expect(opened.show.assets.outro == "assets/outro.mp3")
    #expect(opened.show.assets.bgm == "assets/bgm.mp3")
}

// MARK: - EpisodeBundle

@Test
func episodeBundleCreateStandalone() throws {
    let workspace = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: workspace) }

    let episodeURL = workspace.appendingPathComponent("ep01.maycast")
    let bundle = try EpisodeBundle.create(at: episodeURL)
    #expect(bundle.episode.id == "ep01")
    #expect(bundle.episode.tracks.isEmpty)
    #expect(bundle.episode.show == nil)

    let fm = FileManager.default
    #expect(fm.fileExists(atPath: bundle.manifestURL.path))
    #expect(fm.fileExists(atPath: bundle.sourcesDirectoryURL.path))
    #expect(fm.fileExists(atPath: bundle.intermediateDirectoryURL.path))
    #expect(fm.fileExists(atPath: bundle.assetsDirectoryURL.path))
    #expect(fm.fileExists(atPath: bundle.exportsDirectoryURL.path))
}

@Test
func episodeBundleCreateWithShowSnapshotsAssets() throws {
    let workspace = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: workspace) }

    // Prepare show with assets
    let introSrc = workspace.appendingPathComponent("intro.mp3")
    try writeDummyFile(at: introSrc, content: "INTRO")
    let showURL = workspace.appendingPathComponent("podcast.maycastshow")
    var show = try ShowBundle.create(at: showURL)
    try show.setAssets(intro: introSrc)

    // Create episode under show
    let episodeURL = show.episodesDirectoryURL.appendingPathComponent("ep01.maycast")
    let episode = try EpisodeBundle.create(at: episodeURL, show: show)

    #expect(episode.episode.show != nil)
    let introInEpisode = episode.assetsDirectoryURL.appendingPathComponent("intro.mp3")
    #expect(FileManager.default.fileExists(atPath: introInEpisode.path))
    let contents = try String(contentsOf: introInEpisode, encoding: .utf8)
    #expect(contents == "INTRO")
    #expect(episode.episode.mix.intro == "assets/intro.mp3")
}

@Test
func episodeBundleAppendGeneration() throws {
    let workspace = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: workspace) }

    let episodeURL = workspace.appendingPathComponent("ep01.maycast")
    var bundle = try EpisodeBundle.create(at: episodeURL)
    let track = Track(
        id: "host",
        source: "sources/host.wav",
        current: "intermediate/host/001_import.wav",
        history: ["intermediate/host/001_import.wav"]
    )
    bundle.upsertTrack(track)
    try bundle.appendGeneration(trackID: "host", relativePath: "intermediate/host/002_slice.wav")

    #expect(bundle.track(withID: "host")?.current == "intermediate/host/002_slice.wav")
    #expect(bundle.track(withID: "host")?.history.count == 2)
}

@Test
func episodeBundleNextGenerationNumber() throws {
    let workspace = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: workspace) }

    let episodeURL = workspace.appendingPathComponent("ep01.maycast")
    var bundle = try EpisodeBundle.create(at: episodeURL)
    bundle.upsertTrack(Track(
        id: "host",
        source: "sources/host.wav",
        current: "intermediate/host/001_import.wav",
        history: ["intermediate/host/001_import.wav"]
    ))

    #expect(bundle.nextGenerationNumber(for: "host") == 2)
    #expect(bundle.nextGenerationNumber(for: "guest") == 1)
    #expect(EpisodeBundle.formatGenerationNumber(7) == "007")
}

@Test
func relativePathComputation() {
    let base = URL(fileURLWithPath: "/Users/x/podcast/episodes/ep01.maycast")
    let target = URL(fileURLWithPath: "/Users/x/podcast")
    #expect(EpisodeBundle.relativePath(from: base, to: target) == "../..")
}

// MARK: - JSONValue

@Test
func jsonValueRoundTrip() throws {
    let original = JSONValue.object([
        "cut": .array([.number(12.3), .number(15.8)]),
        "denoise": .bool(true),
        "label": .string("test")
    ])
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
    #expect(decoded == original)
}

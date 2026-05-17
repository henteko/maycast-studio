import ArgumentParser
import Foundation
import MaycastCore

struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List tracks and current generation for an Episode."
    )

    @Option(name: .customLong("project", withSingleDash: true))
    var projectPath: String

    func run() throws {
        let bundle = try EpisodeBundle.open(at: URL(fileURLWithPath: projectPath))
        print("Episode: \(bundle.episode.id) (\(bundle.episode.uuid.uuidString))")
        if let show = bundle.episode.show {
            print("Show:    \(show)")
        }
        print("Tracks:  \(bundle.episode.tracks.count)")
        for track in bundle.episode.tracks {
            print("")
            print("• \(track.id)")
            print("    source:  \(track.source)")
            print("    current: \(track.current)")
            print("    history: \(track.history.count) generation(s)")
        }
    }
}

struct InspectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect",
        abstract: "Show the operation history and parameters for a track."
    )

    @Option(name: .customLong("project", withSingleDash: true))
    var projectPath: String

    @Option(name: .long)
    var track: String

    func run() throws {
        let bundle = try EpisodeBundle.open(at: URL(fileURLWithPath: projectPath))
        guard let trackData = bundle.track(withID: track) else {
            throw RuntimeError.invalidArgument("Track not found: \(track)")
        }
        print("Track: \(trackData.id)")
        print("Source: \(trackData.source)")
        print("History (\(trackData.history.count) generation(s)):")

        for (index, relPath) in trackData.history.enumerated() {
            let generation = index + 1
            let marker = relPath == trackData.current ? "★ current" : "         "
            print("")
            print("  [\(String(format: "%03d", generation))] \(marker)  \(relPath)")
            let paramsURL = bundle.paramsSidecarURL(forGenerationRelativePath: relPath)
            if let pretty = try? readJSONPretty(at: paramsURL) {
                for line in pretty.split(separator: "\n") {
                    print("        \(line)")
                }
            }
        }
    }

    private func readJSONPretty(at url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let obj = try JSONSerialization.jsonObject(with: data)
        let pretty = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        return String(data: pretty, encoding: .utf8)
    }
}

struct RevertCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "revert",
        abstract: "Rewind a track's current pointer to a past generation."
    )

    @Option(name: .customLong("project", withSingleDash: true))
    var projectPath: String

    @Option(name: .long)
    var track: String

    @Option(name: .customLong("to"))
    var generation: Int

    func run() throws {
        var bundle = try EpisodeBundle.open(at: URL(fileURLWithPath: projectPath))
        try bundle.revert(trackID: track, to: generation)
        let trackData = bundle.track(withID: track)!
        print("Reverted '\(track)' to generation \(generation): \(trackData.current)")
    }
}

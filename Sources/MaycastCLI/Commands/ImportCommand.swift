import ArgumentParser
import Foundation
import MaycastCore

struct ImportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Import an audio source into an Episode as a new track."
    )

    @Option(name: .customLong("project", withSingleDash: true),
            help: "Path to the Episode bundle.")
    var projectPath: String

    @Option(name: .customLong("as"),
            help: "Track identifier (e.g. host, guest).")
    var trackID: String

    @Argument(help: "Path to the source audio file.")
    var source: String

    func run() throws {
        let episodeURL = URL(fileURLWithPath: projectPath)
        let sourceURL = URL(fileURLWithPath: source)
        var bundle = try EpisodeBundle.open(at: episodeURL)
        let track = try bundle.importTrack(from: sourceURL, as: trackID)
        print("Imported '\(track.id)' as \(track.source)")
        print("First generation: \(track.current)")
    }
}

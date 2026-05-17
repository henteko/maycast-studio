import ArgumentParser
import Foundation
import MaycastCore

struct InitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Create a new Maycast Episode bundle."
    )

    @Argument(help: "Path of the new Episode bundle (e.g. ep01.maycast).")
    var path: String

    @Option(name: .customLong("show", withSingleDash: true),
            help: "Optional path to a .maycastshow bundle. If provided, the show's assets are snapshot-copied into the new Episode.")
    var showPath: String?

    func run() throws {
        let episodeURL = URL(fileURLWithPath: path)

        var show: ShowBundle?
        if let showPath {
            let showURL = URL(fileURLWithPath: showPath)
            show = try ShowBundle.open(at: showURL)
        }

        let bundle = try EpisodeBundle.create(at: episodeURL, show: show)
        let manifestPath = bundle.manifestURL.path
        print("Created Episode bundle at \(episodeURL.path)")
        print("Manifest: \(manifestPath)")
    }
}

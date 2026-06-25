import ArgumentParser
import Foundation
import MaycastCore

struct ShowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Manage Maycast Show bundles.",
        subcommands: [
            ShowInitCommand.self,
            ShowSetAssetCommand.self,
            ShowListCommand.self,
        ]
    )
}

struct ShowListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the Show bundles found inside a directory."
    )

    @Option(name: .customLong("in", withSingleDash: true),
            help: "Directory to scan for .maycastshow bundles.")
    var directory: String

    @Flag(name: [.customShort("r"), .customLong("recursive")],
          help: "Walk the whole subtree and treat any folder with a show.json as a Show (extension-agnostic).")
    var recursive: Bool = false

    func run() throws {
        let dir = URL(fileURLWithPath: directory)
        let shows = ShowBundle.discover(in: dir, recursive: recursive)
        print("Found \(shows.count) show(s) in \(dir.path)")
        for show in shows {
            // Tab-separated so callers (GUI / E2E / agents) can parse name + path.
            print("\(show.name)\t\(show.url.path)")
        }
    }
}

struct ShowInitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Create a new Maycast Show bundle."
    )

    @Argument(help: "Path of the new Show bundle (e.g. my-podcast.maycastshow).")
    var path: String

    @Option(name: .customLong("name", withSingleDash: true),
            help: "Display name for the show (defaults to the bundle directory name).")
    var name: String?

    func run() throws {
        let showURL = URL(fileURLWithPath: path)
        let bundle = try ShowBundle.create(at: showURL, name: name)
        print("Created Show bundle at \(showURL.path)")
        print("Manifest: \(bundle.manifestURL.path)")
    }
}

struct ShowSetAssetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set-asset",
        abstract: "Set the Show's Intro / Outro / BGM assets (copies into the bundle)."
    )

    @Option(name: .customLong("show", withSingleDash: true),
            help: "Path to the Show bundle.")
    var showPath: String

    @Option(name: .long, help: "Path to the Intro audio file.")
    var intro: String?

    @Option(name: .long, help: "Path to the Outro audio file.")
    var outro: String?

    @Option(name: .long, help: "Path to the BGM audio file.")
    var bgm: String?

    func run() throws {
        let showURL = URL(fileURLWithPath: showPath)
        var bundle = try ShowBundle.open(at: showURL)
        try bundle.setAssets(
            intro: intro.map { URL(fileURLWithPath: $0) },
            outro: outro.map { URL(fileURLWithPath: $0) },
            bgm: bgm.map { URL(fileURLWithPath: $0) }
        )
        print("Updated assets in \(showURL.path)")
        if let i = bundle.show.assets.intro { print("  intro: \(i)") }
        if let o = bundle.show.assets.outro { print("  outro: \(o)") }
        if let b = bundle.show.assets.bgm { print("  bgm:   \(b)") }
    }
}

import ArgumentParser
import Foundation
import MaycastCore

/// `maycast render` — render the episode's per-speaker **video** (mp4) outputs.
/// Audio is produced separately by `maycast mix` (mp3).
struct RenderCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "render",
        abstract: "Render per-speaker mp4 video (cut to match the edited audio, with chapters)."
    )

    @Option(name: .customLong("project", withSingleDash: true),
            help: "Path to the Episode bundle.")
    var projectPath: String

    @Option(name: .customLong("output-dir"),
            help: "Output directory relative to the Episode bundle (default: exports).")
    var outputDir: String = "exports"

    func run() throws {
        let bundleURL = URL(fileURLWithPath: projectPath)
        let artifacts = try VideoRenderer().renderAll(bundleURL: bundleURL, outputDir: outputDir)
        for artifact in artifacts {
            print("mp4\t\(artifact.trackID)\t\(artifact.relativePath)")
        }
        print("Rendered \(artifacts.count) mp4(s) to \(outputDir)/")
    }
}

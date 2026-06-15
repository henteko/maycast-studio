import ArgumentParser
import Foundation
import MaycastCore

/// `maycast export` — produce the episode's final deliverables: one mp3 (the
/// full mix, with intro / outro and chapters) plus one mp4 per speaker that has
/// video (that speaker's video + their own audio + chapters, no intro / outro).
struct ExportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export the episode to mp3 (full mix) and per-speaker mp4 (video tracks)."
    )

    @Option(name: .customLong("project", withSingleDash: true),
            help: "Path to the Episode bundle.")
    var projectPath: String

    @Option(name: .customLong("output-dir"),
            help: "Output directory relative to the Episode bundle (default: exports).")
    var outputDir: String = "exports"

    func run() throws {
        let bundleURL = URL(fileURLWithPath: projectPath)
        let artifacts = try EpisodeExporter().exportAll(bundleURL: bundleURL, outputDir: outputDir)
        for artifact in artifacts {
            switch artifact.kind {
            case .mp3:
                print("mp3\t\(artifact.relativePath)")
            case .mp4:
                print("mp4\t\(artifact.trackID ?? "?")\t\(artifact.relativePath)")
            }
        }
        let mp4s = artifacts.filter { $0.kind == .mp4 }.count
        print("Exported 1 mp3 and \(mp4s) mp4(s) to \(outputDir)/")
    }
}

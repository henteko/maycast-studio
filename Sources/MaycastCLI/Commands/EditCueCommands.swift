import ArgumentParser
import Foundation
import MaycastCore
import MaycastIPC

// MARK: - Parent

struct EditCueCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "editcue",
        abstract: "Detect editing cues in the transcript (spots where a host asked for a cut/retake) and highlight them in the slice editor.",
        subcommands: [
            EditCueGenerateCommand.self,
            EditCueListCommand.self,
            EditCueClearCommand.self,
        ]
    )
}

// MARK: - Shared formatting

private func formatCueTime(_ seconds: Double) -> String {
    let total = max(0, seconds)
    let minutes = Int(total) / 60
    let secs = total - Double(minutes * 60)
    if secs.truncatingRemainder(dividingBy: 1) == 0 {
        return String(format: "%d:%02d", minutes, Int(secs))
    }
    return String(format: "%d:%04.1f", minutes, secs)
}

private func printEditCues(_ bundle: EpisodeBundle) {
    let cues = bundle.sortedEditCues
    print("edit cues (\(cues.count)):")
    for cue in cues {
        print("  [\(formatCueTime(cue.start))] (\(cue.kind.rawValue)) \(cue.text) — \(cue.id)")
    }
}

// MARK: - generate (XPC → EditCueService)

struct EditCueGenerateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "generate",
        abstract: "Detect editing cues from the episode transcript using Gemini."
    )

    @Option(name: .customLong("project", withSingleDash: true))
    var projectPath: String

    @Option(name: .long, help: "Engine override: 'heuristic' / 'fake' (deterministic, offline) or 'gemini' (cloud, default).")
    var engine: String?

    @Option(name: .long, help: "Gemini API key (overrides the GEMINI_API_KEY environment variable).")
    var apiKey: String?

    func run() throws {
        var params: [String: JSONValue] = [:]
        if let engine { params["engine"] = .string(engine) }
        if let apiKey { params["apiKey"] = .string(apiKey) }

        let request = ServiceRequest(
            operation: .editCue,
            episodeBundlePath: URL(fileURLWithPath: projectPath).path,
            params: params.isEmpty ? nil : .object(params)
        )
        let client = ServiceClient(cliBinaryURL: Bundle.main.executableURL)
        let response = try client.invoke(.editCue, request: request)
        if let message = response.message { print(message) }
        if !response.success {
            throw RuntimeError.serviceFailed(response.errorMessage ?? "unknown error")
        }
        let bundle = try EpisodeBundle.open(at: URL(fileURLWithPath: projectPath))
        printEditCues(bundle)
    }
}

// MARK: - list

struct EditCueListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the episode's detected edit cues."
    )

    @Option(name: .customLong("project", withSingleDash: true))
    var projectPath: String

    func run() throws {
        let bundle = try EpisodeBundle.open(at: URL(fileURLWithPath: projectPath))
        printEditCues(bundle)
    }
}

// MARK: - clear

struct EditCueClearCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear",
        abstract: "Remove all detected edit cues from the episode."
    )

    @Option(name: .customLong("project", withSingleDash: true))
    var projectPath: String

    func run() throws {
        var bundle = try EpisodeBundle.open(at: URL(fileURLWithPath: projectPath))
        bundle.setEditCues([])
        try bundle.save()
        print("Cleared all edit cues")
    }
}

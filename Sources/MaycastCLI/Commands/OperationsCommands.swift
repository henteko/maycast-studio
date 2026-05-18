import ArgumentParser
import Foundation
import MaycastCore
import MaycastIPC

// MARK: - Shared helpers

private func cliBinaryURL() -> URL? {
    Bundle.main.executableURL
}

private func runService(_ service: ServiceResolver.Service, request: ServiceRequest) throws -> ServiceResponse {
    let client = ServiceClient(cliBinaryURL: cliBinaryURL())
    return try client.invoke(service, request: request)
}

private func reportAndThrowIfFailed(_ response: ServiceResponse) throws {
    if let message = response.message { print(message) }
    if !response.success {
        throw RuntimeError.serviceFailed(response.errorMessage ?? "unknown error")
    }
}

enum RuntimeError: Error, CustomStringConvertible {
    case serviceFailed(String)
    case invalidArgument(String)

    var description: String {
        switch self {
        case .serviceFailed(let msg): return "Service failed: \(msg)"
        case .invalidArgument(let msg): return "Invalid argument: \(msg)"
        }
    }
}

// MARK: - Transcribe

struct TranscribeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcribe",
        abstract: "Run transcription on a track's current generation."
    )

    @Option(name: .customLong("project", withSingleDash: true))
    var projectPath: String

    @Option(name: .long)
    var track: String

    func run() throws {
        let request = ServiceRequest(
            operation: .transcribe,
            episodeBundlePath: URL(fileURLWithPath: projectPath).path,
            trackID: track
        )
        let response = try runService(.transcribe, request: request)
        try reportAndThrowIfFailed(response)
    }
}

// MARK: - Slice (clip arrangement)

struct SliceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "slice",
        abstract: "Edit a track via clip operations (split / delete / move / apply).",
        subcommands: [
            SliceSplitCommand.self,
            SliceDeleteCommand.self,
            SliceMoveCommand.self,
            SliceApplyCommand.self,
        ]
    )
}

private func invokeSlice(projectPath: String, trackID: String, params: [String: JSONValue]) throws {
    let request = ServiceRequest(
        operation: .slice,
        episodeBundlePath: URL(fileURLWithPath: projectPath).path,
        trackID: trackID,
        params: .object(params)
    )
    let response = try runService(.slice, request: request)
    try reportAndThrowIfFailed(response)
    if let gen = response.generationPath { print("→ \(gen)") }
}

struct SliceSplitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "split",
        abstract: "Split a clip at the given timeline time, producing two abutting clips."
    )

    @Option(name: .customLong("project", withSingleDash: true)) var projectPath: String
    @Option(name: .long) var track: String
    @Option(name: .long, help: "ID of the clip to split.") var clip: String
    @Option(name: .long, parsing: .unconditional, help: "Timeline time (sec) inside the clip.") var at: Double

    func run() throws {
        try invokeSlice(projectPath: projectPath, trackID: track, params: [
            "subOp": .string("split"),
            "clipID": .string(clip),
            "at": .number(at),
        ])
    }
}

struct SliceDeleteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Remove a clip from the arrangement (leaves a silent gap)."
    )

    @Option(name: .customLong("project", withSingleDash: true)) var projectPath: String
    @Option(name: .long) var track: String
    @Option(name: .long, help: "ID of the clip to remove.") var clip: String

    func run() throws {
        try invokeSlice(projectPath: projectPath, trackID: track, params: [
            "subOp": .string("delete"),
            "clipID": .string(clip),
        ])
    }
}

struct SliceMoveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "move",
        abstract: "Move a clip to a new timeline start position."
    )

    @Option(name: .customLong("project", withSingleDash: true)) var projectPath: String
    @Option(name: .long) var track: String
    @Option(name: .long, help: "ID of the clip to move.") var clip: String
    @Option(name: .long, parsing: .unconditional, help: "New timeline start (sec).") var to: Double

    func run() throws {
        try invokeSlice(projectPath: projectPath, trackID: track, params: [
            "subOp": .string("move"),
            "clipID": .string(clip),
            "to": .number(to),
        ])
    }
}

struct SliceApplyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apply",
        abstract: "Apply a complete arrangement (typically from the GUI editor)."
    )

    @Option(name: .customLong("project", withSingleDash: true)) var projectPath: String
    @Option(name: .long) var track: String
    @Option(name: .customLong("arrangement-file"),
            help: "Path to a JSON file containing the new arrangement.") var arrangementFile: String

    func run() throws {
        let url = URL(fileURLWithPath: arrangementFile)
        let arrangementJSON = try JSONCoders.decode(JSONValue.self, from: url)
        try invokeSlice(projectPath: projectPath, trackID: track, params: [
            "subOp": .string("apply"),
            "arrangement": arrangementJSON,
        ])
    }
}

// MARK: - Polish

struct PolishCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "polish",
        abstract: "Apply a polish (cleanup) operation to a track."
    )

    @Option(name: .customLong("project", withSingleDash: true))
    var projectPath: String

    @Option(name: .long)
    var track: String

    @Flag(name: .long, help: "Enable noise reduction.")
    var denoise: Bool = false

    @Flag(name: .customLong("de-esser"), help: "Enable de-esser.")
    var deEsser: Bool = false

    @Option(name: .long, parsing: .unconditional, help: "Target loudness in LUFS (e.g. -16).")
    var loudness: Double?

    func run() throws {
        var params: [String: JSONValue] = [:]
        if denoise { params["denoise"] = .bool(true) }
        if deEsser { params["deEsser"] = .bool(true) }
        if let loudness { params["loudness"] = .number(loudness) }

        let request = ServiceRequest(
            operation: .polish,
            episodeBundlePath: URL(fileURLWithPath: projectPath).path,
            trackID: track,
            params: params.isEmpty ? nil : .object(params)
        )
        let response = try runService(.polish, request: request)
        try reportAndThrowIfFailed(response)
        if let gen = response.generationPath { print("→ \(gen)") }
    }
}

// MARK: - Cross-track silence removal

struct SilenceRemovalCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "silence-removal",
        abstract: "Remove regions where every track is silent (Phase 3.1)."
    )

    @Option(name: .customLong("project", withSingleDash: true))
    var projectPath: String

    @Option(name: .long, help: "Linear-amplitude silence threshold (default 0.01 ≈ -40 dBFS).")
    var threshold: Double = 0.01

    @Option(name: .customLong("min-duration"), help: "Minimum silent duration to consider (seconds, default 0.5).")
    var minDuration: Double = 0.5

    @Option(name: .long, help: "Keep this many seconds of audio inside each cut boundary (default 0.1).")
    var padding: Double = 0.1

    func run() throws {
        let bundleURL = URL(fileURLWithPath: projectPath)
        var bundle = try EpisodeBundle.open(at: bundleURL)
        let results = try bundle.applyCrossTrackSilenceRemoval(
            threshold: Float(threshold),
            minDuration: minDuration,
            padding: padding
        )
        if results.isEmpty {
            print("No cross-track silent regions found (or no tracks).")
        } else {
            for r in results {
                print("→ \(r.trackID): \(r.generationPath)")
            }
        }
    }
}

// MARK: - Mix

struct MixCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mix",
        abstract: "Render the final mix of all tracks."
    )

    @Option(name: .customLong("project", withSingleDash: true))
    var projectPath: String

    @Option(name: .long, help: "Output path relative to the Episode bundle.")
    var output: String?

    func run() throws {
        let request = ServiceRequest(
            operation: .mix,
            episodeBundlePath: URL(fileURLWithPath: projectPath).path,
            outputPath: output
        )
        let response = try runService(.mix, request: request)
        try reportAndThrowIfFailed(response)
        if let path = response.exportPath { print("→ \(path)") }
    }
}

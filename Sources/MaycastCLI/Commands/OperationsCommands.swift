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

// MARK: - Mix

struct MixCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mix",
        abstract: "Render the final mix of all tracks (with optional intro / outro overlap from the episode's MixConfig)."
    )

    @Option(name: .customLong("project", withSingleDash: true))
    var projectPath: String

    @Option(name: .long, help: "Output path relative to the Episode bundle.")
    var output: String?

    @Option(name: .customLong("intro-offset"), parsing: .unconditional,
            help: "Overlap (sec) between intro and voice (overrides MixConfig).")
    var introOffset: Double?

    @Option(name: .customLong("outro-offset"), parsing: .unconditional,
            help: "Overlap (sec) between voice and outro (overrides MixConfig).")
    var outroOffset: Double?

    @Option(name: .customLong("ducking-gain"), parsing: .unconditional,
            help: "Intro / outro level during the overlap, in dB (≤ 0, overrides MixConfig).")
    var duckingGainDB: Double?

    @Option(name: .customLong("ducking-fade"), parsing: .unconditional,
            help: "Ramp time for the duck-down / duck-up, in seconds (overrides MixConfig).")
    var duckingFadeSec: Double?

    func run() throws {
        var params: [String: JSONValue] = [:]
        if let v = introOffset { params["introOffsetSec"] = .number(v) }
        if let v = outroOffset { params["outroOffsetSec"] = .number(v) }
        if let v = duckingGainDB { params["duckingGainDB"] = .number(v) }
        if let v = duckingFadeSec { params["duckingFadeSec"] = .number(v) }

        let request = ServiceRequest(
            operation: .mix,
            episodeBundlePath: URL(fileURLWithPath: projectPath).path,
            params: params.isEmpty ? nil : .object(params),
            outputPath: output
        )
        let response = try runService(.mix, request: request)
        try reportAndThrowIfFailed(response)
        if let path = response.exportPath { print("→ \(path)") }
    }
}

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

private func parseCutRange(_ str: String) throws -> (Double, Double) {
    // "12.3-15.8" or "12.3..15.8"
    let normalized = str.replacingOccurrences(of: "..", with: "-")
    let parts = normalized.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true)
    guard parts.count == 2,
          let start = Double(parts[0]),
          let end = Double(parts[1])
    else {
        throw RuntimeError.invalidArgument("--cut must be in the form START-END (seconds). Got '\(str)'.")
    }
    return (start, end)
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

// MARK: - Slice

struct SliceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "slice",
        abstract: "Apply a slice (cut) operation to a track."
    )

    @Option(name: .customLong("project", withSingleDash: true))
    var projectPath: String

    @Option(name: .long)
    var track: String

    @Option(name: .long, help: "Cut range in seconds, formatted as START-END (e.g. 12.3-15.8).")
    var cut: String

    func run() throws {
        let (start, end) = try parseCutRange(cut)
        let params: JSONValue = .object([
            "cut": .array([.number(start), .number(end)])
        ])
        let request = ServiceRequest(
            operation: .slice,
            episodeBundlePath: URL(fileURLWithPath: projectPath).path,
            trackID: track,
            params: params
        )
        let response = try runService(.slice, request: request)
        try reportAndThrowIfFailed(response)
        if let gen = response.generationPath { print("→ \(gen)") }
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

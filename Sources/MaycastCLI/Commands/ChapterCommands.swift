import ArgumentParser
import Foundation
import MaycastCore
import MaycastIPC

// MARK: - Parent

struct ChapterCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "chapter",
        abstract: "Manage episode chapter markers (generate from transcript, edit, embed into the mix).",
        subcommands: [
            ChapterGenerateCommand.self,
            ChapterListCommand.self,
            ChapterAddCommand.self,
            ChapterEditCommand.self,
            ChapterRemoveCommand.self,
            ChapterApplyCommand.self,
        ]
    )
}

// MARK: - Shared formatting

/// Format seconds as `m:ss` (or `m:ss.s` with a fractional part).
private func formatChapterTime(_ seconds: Double) -> String {
    let total = max(0, seconds)
    let minutes = Int(total) / 60
    let secs = total - Double(minutes * 60)
    if secs.truncatingRemainder(dividingBy: 1) == 0 {
        return String(format: "%d:%02d", minutes, Int(secs))
    }
    return String(format: "%d:%04.1f", minutes, secs)
}

private func printChapters(_ bundle: EpisodeBundle) {
    let chapters = bundle.sortedChapters
    print("chapters (\(chapters.count)):")
    for chapter in chapters {
        print("  [\(formatChapterTime(chapter.start))] \(chapter.title) (\(chapter.source.rawValue)) — \(chapter.id)")
    }
}

// MARK: - generate (XPC → ChapterService)

struct ChapterGenerateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "generate",
        abstract: "Generate chapters from the episode transcript using Gemini."
    )

    @Option(name: .customLong("project", withSingleDash: true))
    var projectPath: String

    @Option(name: .long, help: "Engine override: 'heuristic' / 'fake' (deterministic) or 'gemini' (cloud, default).")
    var engine: String?

    @Option(name: .long, help: "Gemini API key (overrides the GEMINI_API_KEY environment variable).")
    var apiKey: String?

    func run() throws {
        var params: [String: JSONValue] = [:]
        if let engine { params["engine"] = .string(engine) }
        if let apiKey { params["apiKey"] = .string(apiKey) }

        let request = ServiceRequest(
            operation: .chapter,
            episodeBundlePath: URL(fileURLWithPath: projectPath).path,
            params: params.isEmpty ? nil : .object(params)
        )
        let client = ServiceClient(cliBinaryURL: Bundle.main.executableURL)
        let response = try client.invoke(.chapter, request: request)
        if let message = response.message { print(message) }
        if !response.success {
            throw RuntimeError.serviceFailed(response.errorMessage ?? "unknown error")
        }
        let bundle = try EpisodeBundle.open(at: URL(fileURLWithPath: projectPath))
        printChapters(bundle)
    }
}

// MARK: - list

struct ChapterListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the episode's chapters."
    )

    @Option(name: .customLong("project", withSingleDash: true))
    var projectPath: String

    func run() throws {
        let bundle = try EpisodeBundle.open(at: URL(fileURLWithPath: projectPath))
        printChapters(bundle)
    }
}

// MARK: - add

struct ChapterAddCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add a chapter at the given time (seconds, voice timeline)."
    )

    @Option(name: .customLong("project", withSingleDash: true))
    var projectPath: String

    @Option(name: .long, parsing: .unconditional, help: "Start time in seconds.")
    var at: Double

    @Option(name: .long, help: "Chapter title.")
    var title: String

    func run() throws {
        var bundle = try EpisodeBundle.open(at: URL(fileURLWithPath: projectPath))
        let chapter = bundle.addChapter(start: at, title: title, source: .manual)
        try bundle.save()
        print("Added chapter '\(chapter.title)' at \(formatChapterTime(chapter.start)) — \(chapter.id)")
    }
}

// MARK: - edit

struct ChapterEditCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "edit",
        abstract: "Edit a chapter's start time and/or title."
    )

    @Option(name: .customLong("project", withSingleDash: true))
    var projectPath: String

    @Option(name: .long, help: "ID of the chapter to edit.")
    var id: String

    @Option(name: .long, parsing: .unconditional, help: "New start time in seconds.")
    var at: Double?

    @Option(name: .long, help: "New title.")
    var title: String?

    func run() throws {
        var bundle = try EpisodeBundle.open(at: URL(fileURLWithPath: projectPath))
        try bundle.editChapter(id: id, start: at, title: title)
        try bundle.save()
        print("Edited chapter \(id)")
    }
}

// MARK: - remove

struct ChapterRemoveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove a chapter by ID."
    )

    @Option(name: .customLong("project", withSingleDash: true))
    var projectPath: String

    @Option(name: .long, help: "ID of the chapter to remove.")
    var id: String

    func run() throws {
        var bundle = try EpisodeBundle.open(at: URL(fileURLWithPath: projectPath))
        try bundle.removeChapter(id: id)
        try bundle.save()
        print("Removed chapter \(id)")
    }
}

// MARK: - apply (bulk replace from a JSON file)

struct ChapterApplyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apply",
        abstract: "Replace all chapters from a JSON file ([{start, title, source?}, ...])."
    )

    @Option(name: .customLong("project", withSingleDash: true))
    var projectPath: String

    @Option(name: .long, help: "Path to a JSON file with the chapter list.")
    var file: String

    private struct ChapterFileEntry: Decodable {
        var start: Double
        var title: String
        var source: String?
    }

    func run() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: file))
        let entries = try JSONDecoder().decode([ChapterFileEntry].self, from: data)
        let chapters = entries.map { entry in
            Chapter(
                start: entry.start,
                title: entry.title,
                source: entry.source.flatMap(ChapterSource.init(rawValue:)) ?? .manual
            )
        }
        var bundle = try EpisodeBundle.open(at: URL(fileURLWithPath: projectPath))
        bundle.setChapters(chapters)
        try bundle.save()
        print("Applied \(chapters.count) chapter(s)")
    }
}

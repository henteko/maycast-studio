import Foundation
import MaycastCore
import MaycastIPC

// Chapter generation service. Reads every track's current transcript, merges
// them onto one timeline, runs an engine to propose chapter markers, and
// stores them in episode.json under `chapters[]` (voice timeline).
//
// Engine selection (params.engine, else MAYCAST_CHAPTER_ENGINE env):
//   "fake" / "heuristic" → deterministic transcript-segment engine (tests)
//   default ("auto"/"llm") → Gemma 4 via MLX is not yet wired, so we currently
//   fall back to the heuristic engine and say so in the response message.
ServiceHost.run { request in
    guard request.operation == .chapter else {
        return .failure("Unexpected operation \(request.operation.rawValue) for ChapterService")
    }

    var engine = ProcessInfo.processInfo.environment["MAYCAST_CHAPTER_ENGINE"] ?? "auto"
    if case let .object(p)? = request.params, case let .string(e)? = p["engine"] {
        engine = e
    }

    let bundleURL = URL(fileURLWithPath: request.episodeBundlePath)
    var bundle = try EpisodeBundle.open(at: bundleURL)

    let segments = bundle.mergedTranscriptSegments()
    let chapters = ChapterGenerator.heuristic(from: segments)
    bundle.setChapters(chapters)
    try bundle.save()

    let note: String
    switch engine {
    case "fake", "heuristic":
        note = ""
    default:
        note = " (heuristic — Gemma 4 / MLX integration pending)"
    }
    return .ok(message: "Generated \(chapters.count) chapter(s) from \(segments.count) transcript segment(s)\(note)")
}

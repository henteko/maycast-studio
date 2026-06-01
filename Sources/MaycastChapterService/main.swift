import Foundation
import MaycastCore
import MaycastIPC

// Chapter generation service. Reads every track's current transcript, merges
// them onto one timeline, runs an engine to propose chapter markers, and
// stores them in episode.json under `chapters[]` (voice timeline).
//
// Engine selection (params.engine, else MAYCAST_CHAPTER_ENGINE env):
//   "fake" / "heuristic" → deterministic transcript-segment engine (tests)
//   "auto" (default) / "llm" → Apple Foundation Models (on-device); on any
//      failure (model unavailable / generation error) we fall back to the
//      heuristic engine so chapter generation never hard-fails.
ServiceHost.runAsync { request in
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

    let chapters: [Chapter]
    var note = ""
    switch engine {
    case "fake", "heuristic":
        chapters = ChapterGenerator.heuristic(from: segments)
    default:
        // On-device Foundation Models with heuristic fallback.
        do {
            chapters = try await FoundationModelsChapterEngine.generate(from: segments)
            note = " via Foundation Models"
        } catch {
            chapters = ChapterGenerator.heuristic(from: segments)
            note = " (heuristic fallback — \(error))"
        }
    }

    bundle.setChapters(chapters)
    try bundle.save()
    return .ok(message: "Generated \(chapters.count) chapter(s) from \(segments.count) transcript segment(s)\(note)")
}

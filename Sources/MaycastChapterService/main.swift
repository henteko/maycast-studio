import Foundation
import MaycastCore
import MaycastIPC

// Chapter generation service. Reads every track's current transcript, merges
// them onto one timeline, runs an engine to propose chapter markers, and
// stores them in episode.json under `chapters[]` (voice timeline).
//
// Engine selection (params.engine, else MAYCAST_CHAPTER_ENGINE env):
//   "fake" / "heuristic" → deterministic transcript-segment engine (tests)
//   "auto" (default) / "llm" / "gemini" → Google Gemini (cloud); needs an API
//      key (params.apiKey, else GEMINI_API_KEY env). On any failure (no key,
//      network error, bad response) we fall back to the heuristic engine so
//      chapter generation never hard-fails.
ServiceHost.runAsync { request in
    guard request.operation == .chapter else {
        return .failure("Unexpected operation \(request.operation.rawValue) for ChapterService")
    }

    let env = ProcessInfo.processInfo.environment
    var engine = env["MAYCAST_CHAPTER_ENGINE"] ?? "auto"
    var apiKey = env["GEMINI_API_KEY"] ?? ""
    let model = env["MAYCAST_GEMINI_MODEL"] ?? GeminiChapterEngine.defaultModel
    if case let .object(p)? = request.params {
        if case let .string(e)? = p["engine"] { engine = e }
        if case let .string(k)? = p["apiKey"] { apiKey = k }
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
        // Cloud Gemini with heuristic fallback.
        do {
            chapters = try await GeminiChapterEngine(apiKey: apiKey, model: model)
                .generate(from: segments)
            note = " via Gemini (\(model))"
        } catch {
            chapters = ChapterGenerator.heuristic(from: segments)
            note = " (heuristic fallback — \(error))"
        }
    }

    bundle.setChapters(chapters)
    try bundle.save()
    return .ok(message: "Generated \(chapters.count) chapter(s) from \(segments.count) transcript segment(s)\(note)")
}

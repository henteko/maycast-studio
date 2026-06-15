import Foundation
import MaycastCore
import MaycastIPC

// Edit-cue detection service. Reads every track's current transcript, merges
// them onto one timeline, finds utterances that are editing instructions, and
// stores them in episode.json under `editCues[]` (voice timeline).
//
// Engine selection (params.engine, else MAYCAST_EDITCUE_ENGINE env):
//   "fake" / "heuristic" → deterministic keyword engine (tests, offline)
//   "auto" (default) / "llm" / "gemini" → Google Gemini (cloud); needs an API
//      key (params.apiKey, else GEMINI_API_KEY env). UNLIKE chapters there is no
//      heuristic fallback: any failure is returned as a service failure so the
//      user knows detection didn't run.
ServiceHost.runAsync { request in
    guard request.operation == .editCue else {
        return .failure("Unexpected operation \(request.operation.rawValue) for EditCueService")
    }

    let env = ProcessInfo.processInfo.environment
    var engine = env["MAYCAST_EDITCUE_ENGINE"] ?? "auto"
    var apiKey = env["GEMINI_API_KEY"] ?? ""
    let model = env["MAYCAST_GEMINI_MODEL"] ?? GeminiEditCueEngine.defaultModel
    if case let .object(p)? = request.params {
        if case let .string(e)? = p["engine"] { engine = e }
        if case let .string(k)? = p["apiKey"] { apiKey = k }
    }

    let bundleURL = URL(fileURLWithPath: request.episodeBundlePath)
    var bundle = try EpisodeBundle.open(at: bundleURL)
    let segments = bundle.mergedTranscriptSegments()

    let cues: [EditCue]
    var note = ""
    switch engine {
    case "fake", "heuristic":
        cues = EditCueGenerator.heuristic(from: segments)
    default:
        // Cloud Gemini, no fallback — a failure here fails the whole operation.
        cues = try await GeminiEditCueEngine(apiKey: apiKey, model: model)
            .detect(from: segments)
        note = " via Gemini (\(model))"
    }

    bundle.setEditCues(cues)
    try bundle.save()
    return .ok(message: "Found \(cues.count) edit cue(s) from \(segments.count) transcript segment(s)\(note)")
}

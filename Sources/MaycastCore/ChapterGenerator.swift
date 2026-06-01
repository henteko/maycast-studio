import Foundation

/// Produces chapter markers from a transcript.
///
/// The real product uses a local LLM (Gemma 4 via MLX) — that path is wired
/// separately (docs/chapters.md §4). This heuristic engine is the deterministic
/// fallback used for tests (`MAYCAST_CHAPTER_ENGINE=fake`) and as an interim
/// default until the model is integrated: it walks the merged transcript and
/// starts a new chapter whenever enough time has elapsed since the last one.
public enum ChapterGenerator {

    public enum Engine: String, Sendable {
        case heuristic   // deterministic, transcript-segment based
        case llm         // Gemma 4 via MLX (not yet wired)
    }

    /// Generate chapters (voice timeline) from transcript segments.
    /// - Parameter minSpacingSec: minimum gap between consecutive chapters.
    public static func heuristic(
        from segments: [TranscriptSegment],
        minSpacingSec: Double = 30
    ) -> [Chapter] {
        let sorted = segments.sorted { $0.start < $1.start }
        var chapters: [Chapter] = []
        var lastStart = -Double.greatestFiniteMagnitude

        for segment in sorted {
            guard segment.start - lastStart >= minSpacingSec else { continue }
            let title = chapterTitle(from: segment.text, fallbackIndex: chapters.count + 1)
            chapters.append(Chapter(start: segment.start, title: title, source: .generated))
            lastStart = segment.start
        }
        return chapters
    }

    /// Trim a segment's text into a concise chapter title.
    private static func chapterTitle(from text: String, fallbackIndex: Int) -> String {
        let cleaned = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "Chapter \(fallbackIndex)" }
        let limit = 28
        if cleaned.count <= limit { return cleaned }
        let prefix = cleaned.prefix(limit).trimmingCharacters(in: .whitespaces)
        return "\(prefix)…"
    }
}

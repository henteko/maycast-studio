import Foundation

/// Produces chapter markers from a transcript.
///
/// The product generates chapters with Google Gemini (`GeminiChapterEngine`).
/// This heuristic engine is the deterministic fallback used for tests
/// (`MAYCAST_CHAPTER_ENGINE=fake`) and whenever Gemini is unavailable (no API
/// key / network error): it walks the merged transcript and starts a new
/// chapter whenever enough time has elapsed since the last one.
public enum ChapterGenerator {

    public enum Engine: String, Sendable {
        case heuristic   // deterministic, transcript-segment based
        case llm         // Gemini (cloud) — see GeminiChapterEngine
    }

    /// Generate chapters (voice timeline) from transcript segments.
    ///
    /// Segments are grouped into fixed time windows; each window becomes one
    /// chapter whose title is built by concatenating that window's transcript
    /// text. This stays readable even when the transcript is word- or
    /// character-level (otherwise titles would be a single character).
    ///
    /// - Parameter windowSec: target length of each chapter window.
    public static func heuristic(
        from segments: [TranscriptSegment],
        windowSec: Double = 90
    ) -> [Chapter] {
        let sorted = segments.sorted { $0.start < $1.start }
        guard !sorted.isEmpty else { return [] }

        var chapters: [Chapter] = []
        var i = 0
        while i < sorted.count {
            let chapterStart = sorted[i].start
            var windowText = ""
            var j = i
            while j < sorted.count, sorted[j].start - chapterStart < windowSec {
                let piece = sorted[j].text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !piece.isEmpty {
                    if !windowText.isEmpty, needsSpace(between: windowText, and: piece) {
                        windowText += " "
                    }
                    windowText += piece
                }
                j += 1
            }
            let title = chapterTitle(from: windowText, fallbackIndex: chapters.count + 1)
            chapters.append(Chapter(start: chapterStart, title: title, source: .generated))
            i = max(j, i + 1)
        }
        return chapters
    }

    /// Join word-level transcripts with spaces, but not CJK text (which has no
    /// inter-word spaces).
    private static func needsSpace(between left: String, and right: String) -> Bool {
        guard let l = left.unicodeScalars.last, let r = right.unicodeScalars.first else { return false }
        func isCJK(_ s: Unicode.Scalar) -> Bool {
            (0x3040...0x30FF).contains(s.value) ||   // hiragana / katakana
            (0x4E00...0x9FFF).contains(s.value) ||   // CJK unified
            (0xFF00...0xFFEF).contains(s.value)      // full-width forms
        }
        return !(isCJK(l) || isCJK(r))
    }

    /// Trim concatenated window text into a concise chapter title.
    private static func chapterTitle(from text: String, fallbackIndex: Int) -> String {
        let cleaned = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "Chapter \(fallbackIndex)" }
        let limit = 24
        if cleaned.count <= limit { return cleaned }
        let prefix = cleaned.prefix(limit).trimmingCharacters(in: .whitespaces)
        return "\(prefix)…"
    }
}

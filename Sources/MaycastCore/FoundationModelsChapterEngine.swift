import Foundation
import FoundationModels

/// Chapter generation backed by Apple's on-device Foundation Models.
///
/// No external dependency or model download: the system model ships with the
/// OS (macOS 26+) and runs on device. Guided generation (`@Generable`) yields a
/// typed chapter list directly, so there's no JSON parsing. Any failure
/// (model unavailable, generation error) is thrown to the caller, which falls
/// back to the heuristic engine. Shared by the XPC service and the GUI.
public enum FoundationModelsChapterEngine {

    /// Typed output schema the model is constrained to produce. The count
    /// bounds are hard constraints, which keeps the model from emitting one
    /// chapter per transcript line — chapters should mark major topic shifts.
    @Generable
    struct ChapterList {
        @Guide(
            description: "Major topic sections of the episode, ordered by start time. Merge consecutive same-topic content into one chapter.",
            .minimumCount(2), .maximumCount(8)
        )
        var chapters: [GeneratedChapter]
    }

    @Generable
    struct GeneratedChapter {
        // The model picks the CHUNK NUMBER where the chapter begins rather than
        // a free-form timestamp: LLMs reliably select an index from a list but
        // are poor at reproducing exact numbers from long context (which made
        // earlier timestamps drift / bunch up). We map the chunk back to its
        // real start time afterwards.
        @Guide(description: "The chunk number (from the numbered transcript) where this chapter begins.")
        var chunk: Int
        @Guide(description: "Short, descriptive chapter title in the same language as the transcript.")
        var title: String
    }

    public enum EngineError: Error, CustomStringConvertible {
        case unavailable(String)
        public var description: String {
            switch self {
            case .unavailable(let reason): return "Foundation Models unavailable: \(reason)"
            }
        }
    }

    /// Generate chapters (voice timeline) from transcript segments. Throws if
    /// the on-device model is unavailable or generation fails.
    public static func generate(from segments: [TranscriptSegment]) async throws -> [Chapter] {
        guard !segments.isEmpty else { return [] }

        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            throw EngineError.unavailable(String(describing: model.availability))
        }

        let buckets = makeBuckets(from: segments)
        guard !buckets.isEmpty else { return [] }

        let session = LanguageModelSession {
            """
            You divide a podcast transcript into chapters for podcast players. \
            The transcript is given as numbered chunks in chronological order. \
            Group consecutive chunks about the same topic into ONE chapter, and \
            start a new chapter only at a MAJOR topic transition (a new segment, \
            a new guest, a Q&A or listener-mail section, the closing). Produce a \
            small number of meaningful chapters — typically 4 to 8 — spread across \
            the WHOLE episode, NOT one per chunk. For each chapter, return the \
            chunk number where it begins (the first chapter begins at chunk 0). \
            Write each chapter title in the EXACT same language as the transcript \
            — if the transcript is Japanese, the titles must be Japanese. Do not \
            translate. Keep titles concise and descriptive.
            """
        }

        let response = try await session.respond(
            to: prompt(for: buckets),
            generating: ChapterList.self
        )

        // Map each chapter's chunk index back to its real start time. Clamp out
        // -of-range indices, drop empty titles, sort, and de-duplicate by start.
        let lastIndex = buckets.count - 1
        var result: [Chapter] = response.content.chapters.compactMap { gc in
            let index = min(max(gc.chunk, 0), lastIndex)
            let title = gc.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return Chapter(start: buckets[index].start, title: title, source: .generated)
        }
        result.sort { $0.start < $1.start }
        var seenStarts = Set<Double>()
        return result.filter { seenStarts.insert($0.start).inserted }
    }

    // MARK: - Transcript bucketing

    // The on-device model has a small context window, so a full (often
    // word/character-level) transcript would overflow it. We downsample into at
    // most `maxBuckets` chunks, each capped at `perBucketChars`, spanning the
    // whole episode so chapter starts can land anywhere on the real timeline.
    private static let maxBuckets = 28
    private static let perBucketChars = 44

    private static func makeBuckets(from segments: [TranscriptSegment]) -> [(start: Double, text: String)] {
        let sorted = segments.sorted { $0.start < $1.start }
        guard let first = sorted.first else { return [] }
        let start = first.start
        let duration = max(0, (sorted.last?.end ?? 0) - start)
        let bucketSec = max(15.0, duration / Double(maxBuckets))

        var buckets: [(start: Double, text: String)] = []
        var bucketStart = start
        var bucketText = ""
        func flush() {
            let t = bucketText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { buckets.append((bucketStart, String(t.prefix(perBucketChars)))) }
        }
        for segment in sorted {
            if segment.start - bucketStart >= bucketSec {
                flush()
                bucketStart = segment.start
                bucketText = ""
            }
            bucketText += segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        flush()
        return buckets
    }

    private static func prompt(for buckets: [(start: Double, text: String)]) -> String {
        var lines = "Numbered transcript chunks (chronological). Use the chunk number to mark where a chapter begins:\n"
        for (i, bucket) in buckets.enumerated() {
            lines += "\(i): \(bucket.text)\n"
        }
        lines += "\nReturn the chapters now."
        return lines
    }
}

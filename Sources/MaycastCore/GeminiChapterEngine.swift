import Foundation

/// Chapter generation backed by Google's Gemini API (Generative Language API).
///
/// Replaces the previous on-device engine, whose accuracy was too low for
/// useful chapter boundaries. Gemini is a cloud call, so it
/// needs an API key (GUI: macOS Keychain; CLI/XPC: `GEMINI_API_KEY`). Any
/// failure (no key, network error, bad response) is thrown to the caller, which
/// falls back to the heuristic engine so chapter generation never hard-fails.
///
/// The model receives the FULL transcript as numbered, timestamped lines and
/// returns, via structured JSON output (`responseSchema`), the line index where
/// each chapter begins. We map the index back to that line's real start time
/// afterwards — LLMs reliably pick an index from a list but are poor at
/// reproducing exact timestamps from long context (which made earlier attempts
/// drift / bunch up). Earlier the transcript was downsampled into time buckets
/// with truncated text; passing the whole transcript materially improved the
/// chapter boundaries.
public struct GeminiChapterEngine: Sendable {

    /// Default model id. Overridable via the initializer / `MAYCAST_GEMINI_MODEL`.
    public static let defaultModel = "gemini-3.5-flash"

    /// Base URL of the Generative Language API (v1beta).
    public static let defaultBaseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!

    public enum EngineError: Error, CustomStringConvertible {
        case missingAPIKey
        case http(status: Int, body: String?)
        case blocked(reason: String)
        case emptyResponse
        case decoding(String)

        public var description: String {
            switch self {
            case .missingAPIKey:
                return "Gemini API key is not set"
            case .http(let status, let body):
                return "Gemini API HTTP \(status)\(body.map { ": \($0)" } ?? "")"
            case .blocked(let reason):
                return "Gemini blocked the request: \(reason)"
            case .emptyResponse:
                return "Gemini returned no chapters"
            case .decoding(let detail):
                return "Gemini response could not be parsed: \(detail)"
            }
        }
    }

    private let apiKey: String
    private let model: String
    private let baseURL: URL
    private let session: URLSession

    public init(
        apiKey: String,
        model: String = GeminiChapterEngine.defaultModel,
        baseURL: URL = GeminiChapterEngine.defaultBaseURL,
        session: URLSession? = nil
    ) {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 60
            config.timeoutIntervalForResource = 120
            config.waitsForConnectivity = true
            self.session = URLSession(configuration: config)
        }
    }

    /// Generate chapters (voice timeline) from transcript segments. Throws on
    /// any API / parsing failure so the caller can fall back to the heuristic.
    public func generate(from segments: [TranscriptSegment]) async throws -> [Chapter] {
        guard !apiKey.isEmpty else { throw EngineError.missingAPIKey }
        guard !segments.isEmpty else { return [] }

        let lines = Self.makeLines(from: segments)
        guard !lines.isEmpty else { return [] }

        let text = try await requestCompletion(lines: lines)
        let list = try Self.decodeChapterList(from: text)

        // Map each chapter's line index back to its real start time. Clamp out
        // -of-range indices, drop empty titles, sort, and de-duplicate by start.
        let lastIndex = lines.count - 1
        var result: [Chapter] = list.chapters.compactMap { gc in
            let index = min(max(gc.chunk, 0), lastIndex)
            let title = gc.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return Chapter(start: lines[index].start, title: title, source: .generated)
        }
        result.sort { $0.start < $1.start }
        var seenStarts = Set<Double>()
        result = result.filter { seenStarts.insert($0.start).inserted }
        guard !result.isEmpty else { throw EngineError.emptyResponse }
        return result
    }

    // MARK: - Networking

    private func requestCompletion(lines: [(start: Double, text: String)]) async throws -> String {
        let endpoint = baseURL.appendingPathComponent("models/\(model):generateContent")
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Header auth keeps the key out of URLs (and out of any URL logging).
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        req.httpBody = try JSONSerialization.data(withJSONObject: Self.requestBody(
            system: Self.systemInstruction,
            user: Self.prompt(for: lines)
        ))

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw EngineError.http(status: -1, body: "non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw EngineError.http(status: http.statusCode, body: String(data: data, encoding: .utf8))
        }

        let decoded = try JSONDecoder().decode(GenerateResponse.self, from: data)
        if let reason = decoded.promptFeedback?.blockReason {
            throw EngineError.blocked(reason: reason)
        }
        guard let text = decoded.candidates?.first?.content?.parts?
            .compactMap(\.text).joined(), !text.isEmpty
        else {
            throw EngineError.emptyResponse
        }
        return text
    }

    private static func decodeChapterList(from text: String) throws -> ChapterList {
        guard let data = text.data(using: .utf8) else {
            throw EngineError.decoding("non-UTF8 body")
        }
        do {
            return try JSONDecoder().decode(ChapterList.self, from: data)
        } catch {
            throw EngineError.decoding(String(describing: error))
        }
    }

    // MARK: - Request / response shapes

    /// The structured-output schema constraining Gemini to a chapter list.
    /// Built as a plain dictionary to avoid recursive-`Encodable` gymnastics.
    private static func requestBody(system: String, user: String) -> [String: Any] {
        [
            "system_instruction": ["parts": [["text": system]]],
            "contents": [["parts": [["text": user]]]],
            "generationConfig": [
                "responseMimeType": "application/json",
                "responseSchema": [
                    "type": "OBJECT",
                    "properties": [
                        "chapters": [
                            "type": "ARRAY",
                            "items": [
                                "type": "OBJECT",
                                "properties": [
                                    "chunk": ["type": "INTEGER"],
                                    "title": ["type": "STRING"],
                                ],
                                "required": ["chunk", "title"],
                                "propertyOrdering": ["chunk", "title"],
                            ],
                        ]
                    ],
                    "required": ["chapters"],
                ],
                "temperature": 0.3,
            ],
        ]
    }

    private struct GenerateResponse: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                struct Part: Decodable { let text: String? }
                let parts: [Part]?
            }
            let content: Content?
        }
        struct PromptFeedback: Decodable { let blockReason: String? }
        let candidates: [Candidate]?
        let promptFeedback: PromptFeedback?
    }

    private struct ChapterList: Decodable {
        struct GeneratedChapter: Decodable {
            let chunk: Int
            let title: String
        }
        let chapters: [GeneratedChapter]
    }

    // MARK: - Prompt

    private static let systemInstruction = """
        You divide a podcast transcript into chapters for podcast players. \
        The transcript is given IN FULL as numbered lines in chronological \
        order; each line is prefixed with its timestamp. Read the whole \
        transcript, then group consecutive lines about the same topic into ONE \
        chapter, starting a new chapter only at a MAJOR topic transition (a new \
        segment, a new guest, a Q&A or listener-mail section, the closing). \
        Produce a small number of meaningful chapters — typically 4 to 8 — \
        spread across the WHOLE episode, NOT one per line. \
        IMPORTANT — separating the opening from the main topic: Almost every \
        episode begins with an opening preamble before the real content — \
        greetings, the show/host introduction, casual chit-chat, \
        housekeeping, a recap, announcing today's theme, or remarks like \
        "before we get into today's topic". You MUST make this opening its \
        OWN chapter at line 0 (title it e.g. "オープニング" or "導入"), and \
        then START A SEPARATE CHAPTER at the line where the hosts actually \
        begin discussing or explaining the first substantive topic, so a \
        listener can jump straight to the main topic. Do NOT fold the opening \
        into the first topical chapter. As a strong signal: if you are about \
        to write a title that joins two different things with "と" / "and" / \
        "&" (e.g. "導入とエンジンXの概要"), that means you merged two chapters \
        that should be split — split them into separate chapters instead. \
        Only skip the opening chapter if the episode truly dives into the \
        main subject from the very first line with no preamble at all. \
        For each chapter, \
        return the line number where it begins (the first chapter begins at \
        line 0). Write each chapter title in the EXACT same language as the \
        transcript — if the transcript is Japanese, the titles must be \
        Japanese. Do not translate. Keep titles concise and descriptive.
        """

    private static func prompt(for lines: [(start: Double, text: String)]) -> String {
        var out = "Full transcript as numbered lines (chronological), each formatted `<index> [<mm:ss>] <text>`. Use the line number to mark where a chapter begins:\n"
        for (i, line) in lines.enumerated() {
            out += "\(i) [\(formatTimestamp(line.start))] \(line.text)\n"
        }
        out += "\nReturn the chapters now."
        return out
    }

    private static func formatTimestamp(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Transcript lines

    // Pass the WHOLE transcript (no truncation). Word/character-level segments
    // are merged into readable lines, each carrying the real start time of its
    // first segment, so chapter starts map back to actual timeline positions.
    // A line breaks at a sentence end, once it reaches `maxLineChars`, or after
    // a pause of `lineGapSec` (which usually marks a section boundary).
    private static let maxLineChars = 140
    private static let lineGapSec = 8.0

    static func makeLines(from segments: [TranscriptSegment]) -> [(start: Double, text: String)] {
        let sorted = segments.sorted { $0.start < $1.start }

        var lines: [(start: Double, text: String)] = []
        var lineStart: Double? = nil
        var lineText = ""
        var prevEnd: Double? = nil

        func flush() {
            let t = lineText.trimmingCharacters(in: .whitespacesAndNewlines)
            if let s = lineStart, !t.isEmpty { lines.append((s, t)) }
            lineStart = nil
            lineText = ""
        }

        for segment in sorted {
            let piece = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if piece.isEmpty { continue }
            // A long pause closes the current line so the new topic starts fresh.
            if lineStart != nil, let pe = prevEnd, segment.start - pe >= lineGapSec {
                flush()
            }
            if lineStart == nil { lineStart = segment.start }
            if !lineText.isEmpty, needsSpace(between: lineText, and: piece) {
                lineText += " "
            }
            lineText += piece
            prevEnd = segment.end
            if lineText.count >= maxLineChars || endsSentence(lineText) {
                flush()
            }
        }
        flush()
        return lines
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

    /// True when the accumulated text ends on sentence-terminating punctuation
    /// (ASCII or Japanese), so the line can break at a natural boundary.
    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.unicodeScalars.last else { return false }
        return "。．.！？!?…".unicodeScalars.contains(last)
    }
}

import Foundation

/// Edit-cue detection backed by Google's Gemini API (Generative Language API).
///
/// Finds utterances in the transcript where a host verbally asks for an edit —
/// "ここカットで", "今の言い直す", "後で飛ばして" — so the slice editor can
/// highlight cut points. Gemini is used because the transcript is imperfect
/// (ASR errors) and the same words appear in normal speech: distinguishing a
/// genuine *editing instruction* from a topical mention needs context, which a
/// keyword match alone can't do.
///
/// Like `GeminiChapterEngine`, the model receives the FULL transcript as
/// numbered, timestamped lines and returns, via structured JSON output, the
/// line index of each editing instruction plus its kind. We map the index back
/// to that line's real time range afterwards.
///
/// There is intentionally NO heuristic fallback: detection is Gemini-only. Any
/// failure (no key, network error, bad response) is thrown to the caller, which
/// surfaces it so the user knows detection didn't run.
public struct GeminiEditCueEngine: Sendable {

    public static let defaultModel = "gemini-3.5-flash"
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
                return "Gemini returned no response"
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
        model: String = GeminiEditCueEngine.defaultModel,
        baseURL: URL = GeminiEditCueEngine.defaultBaseURL,
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

    /// Detect editing cues (voice timeline) from transcript segments. Throws on
    /// any API / parsing failure. Returns an empty array when the transcript
    /// genuinely contains no editing instructions.
    public func detect(from segments: [TranscriptSegment]) async throws -> [EditCue] {
        guard !apiKey.isEmpty else { throw EngineError.missingAPIKey }
        guard !segments.isEmpty else { return [] }

        let lines = Self.makeLines(from: segments)
        guard !lines.isEmpty else { return [] }

        let text = try await requestCompletion(lines: lines)
        let list = try Self.decodeCueList(from: text)

        let lastIndex = lines.count - 1
        var result: [EditCue] = list.cues.compactMap { gc in
            let index = min(max(gc.chunk, 0), lastIndex)
            let line = lines[index]
            let body = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return nil }
            let kind = EditCueKind(rawValue: gc.kind) ?? .other
            return EditCue(start: line.start, end: line.end, text: body, kind: kind)
        }
        result.sort { $0.start < $1.start }
        var seenStarts = Set<Double>()
        result = result.filter { seenStarts.insert($0.start).inserted }
        return result
    }

    // MARK: - Networking

    private func requestCompletion(lines: [(start: Double, end: Double, text: String)]) async throws -> String {
        let endpoint = baseURL.appendingPathComponent("models/\(model):generateContent")
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
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

    private static func decodeCueList(from text: String) throws -> CueList {
        guard let data = text.data(using: .utf8) else {
            throw EngineError.decoding("non-UTF8 body")
        }
        do {
            return try JSONDecoder().decode(CueList.self, from: data)
        } catch {
            throw EngineError.decoding(String(describing: error))
        }
    }

    // MARK: - Request / response shapes

    private static func requestBody(system: String, user: String) -> [String: Any] {
        [
            "system_instruction": ["parts": [["text": system]]],
            "contents": [["parts": [["text": user]]]],
            "generationConfig": [
                "responseMimeType": "application/json",
                "responseSchema": [
                    "type": "OBJECT",
                    "properties": [
                        "cues": [
                            "type": "ARRAY",
                            "items": [
                                "type": "OBJECT",
                                "properties": [
                                    "chunk": ["type": "INTEGER"],
                                    "kind": [
                                        "type": "STRING",
                                        "enum": EditCueKind.allCases.map(\.rawValue),
                                    ],
                                ],
                                "required": ["chunk", "kind"],
                                "propertyOrdering": ["chunk", "kind"],
                            ],
                        ]
                    ],
                    "required": ["cues"],
                ],
                "temperature": 0.1,
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

    private struct CueList: Decodable {
        struct GeneratedCue: Decodable {
            let chunk: Int
            let kind: String
        }
        let cues: [GeneratedCue]
    }

    // MARK: - Prompt

    private static let systemInstruction = """
        You scan a podcast recording transcript for EDITING INSTRUCTIONS — \
        moments where a speaker, while recording, verbally asks for part of the \
        recording to be edited out or redone in post-production. The transcript \
        is given IN FULL as numbered lines in chronological order. Return the \
        line number of EACH line that contains an editing instruction, with its \
        kind. Map each to one of these kinds:\
        \n- "cut": remove this part (e.g. "ここカットで", "今のところ切って", \
        "ここ要らない", "さっきのは使わないで").\
        \n- "retake": the speaker flubbed and redoes it (e.g. "今のなしで", \
        "もう一回言い直します", "噛んだのでもう一度", "撮り直し").\
        \n- "skip": skip or handle later (e.g. "ここ飛ばして", "後で").\
        \n- "other": any other clear editing instruction that doesn't fit above.\
        \nThe transcript comes from imperfect speech recognition, so the wording \
        may be slightly garbled — match by MEANING, not exact spelling (e.g. \
        "カット" might appear as "勝つと" / "カットで" / "かっと"). \
        CRITICAL: only flag a line when the speaker is genuinely instructing an \
        edit of the recording. Do NOT flag normal topical speech that merely \
        contains these words — e.g. "コストカットの話" (a business topic), \
        "ケーブルを切る" (describing an action in a story), or "後で説明します" \
        (a content promise) are NOT editing instructions. When in doubt, do not \
        flag it. If there are no editing instructions at all, return an empty \
        list.
        """

    private static func prompt(for lines: [(start: Double, end: Double, text: String)]) -> String {
        var out = "Full transcript as numbered lines (chronological), each formatted `<index> [<mm:ss>] <text>`. Return the line number of each editing instruction:\n"
        for (i, line) in lines.enumerated() {
            out += "\(i) [\(formatTimestamp(line.start))] \(line.text)\n"
        }
        out += "\nReturn the editing-instruction lines now (empty list if none)."
        return out
    }

    private static func formatTimestamp(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Transcript lines

    // Merge word/character-level segments into readable lines, each carrying the
    // real start AND end time, so a flagged line maps back to an exact range.
    // Mirrors GeminiChapterEngine.makeLines but also tracks the line end.
    private static let maxLineChars = 140
    private static let lineGapSec = 8.0

    static func makeLines(from segments: [TranscriptSegment]) -> [(start: Double, end: Double, text: String)] {
        let sorted = segments.sorted { $0.start < $1.start }

        var lines: [(start: Double, end: Double, text: String)] = []
        var lineStart: Double? = nil
        var lineEnd: Double = 0
        var lineText = ""
        var prevEnd: Double? = nil

        func flush() {
            let t = lineText.trimmingCharacters(in: .whitespacesAndNewlines)
            if let s = lineStart, !t.isEmpty { lines.append((s, lineEnd, t)) }
            lineStart = nil
            lineText = ""
        }

        for segment in sorted {
            let piece = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if piece.isEmpty { continue }
            if lineStart != nil, let pe = prevEnd, segment.start - pe >= lineGapSec {
                flush()
            }
            if lineStart == nil { lineStart = segment.start }
            if !lineText.isEmpty, needsSpace(between: lineText, and: piece) {
                lineText += " "
            }
            lineText += piece
            lineEnd = segment.end
            prevEnd = segment.end
            if lineText.count >= maxLineChars || endsSentence(lineText) {
                flush()
            }
        }
        flush()
        return lines
    }

    private static func needsSpace(between left: String, and right: String) -> Bool {
        guard let l = left.unicodeScalars.last, let r = right.unicodeScalars.first else { return false }
        func isCJK(_ s: Unicode.Scalar) -> Bool {
            (0x3040...0x30FF).contains(s.value) ||
            (0x4E00...0x9FFF).contains(s.value) ||
            (0xFF00...0xFFEF).contains(s.value)
        }
        return !(isCJK(l) || isCJK(r))
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.unicodeScalars.last else { return false }
        return "。．.！？!?…".unicodeScalars.contains(last)
    }
}

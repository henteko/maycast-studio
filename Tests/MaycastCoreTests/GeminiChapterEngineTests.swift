import Testing
import Foundation
@testable import MaycastCore

@Suite("GeminiChapterEngine (URLProtocol stub)", .serialized)
struct GeminiChapterEngineTests {

    private func makeStubSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GeminiStubURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// Three segments spaced well past the line-gap threshold each become their
    /// own line, so line indices map to predictable start times (0, 30, 60).
    private let segments: [TranscriptSegment] = [
        TranscriptSegment(start: 0,  end: 5,  text: "今日はポッドキャストの編集について話します"),
        TranscriptSegment(start: 30, end: 35, text: "次にチャプター機能の紹介です"),
        TranscriptSegment(start: 60, end: 65, text: "最後にまとめとお知らせ"),
    ]

    @Test
    func mapsChunkIndicesToStartTimesAndSendsStructuredRequest() async throws {
        let session = makeStubSession()
        GeminiStubURLProtocol.responder = { req in
            // Endpoint embeds the model id; auth is via the x-goog-api-key header.
            #expect(req.httpMethod == "POST")
            #expect(req.url?.path.hasSuffix("/models/gemini-3.5-flash:generateContent") == true)
            #expect(req.value(forHTTPHeaderField: "x-goog-api-key") == "test-key")

            // Body requests structured JSON output.
            let body = try JSONSerialization.jsonObject(with: req.bodyData ?? Data()) as! [String: Any]
            let genConfig = body["generationConfig"] as! [String: Any]
            #expect(genConfig["responseMimeType"] as? String == "application/json")
            #expect(genConfig["responseSchema"] != nil)

            // Gemini returns the schema-conforming JSON as the candidate's text.
            let inner = #"{"chapters":[{"chunk":0,"title":"イントロ"},{"chunk":2,"title":"まとめ"}]}"#
            let envelope: [String: Any] = [
                "candidates": [["content": ["parts": [["text": inner]]]]]
            ]
            return (200, try JSONSerialization.data(withJSONObject: envelope))
        }

        let engine = GeminiChapterEngine(apiKey: "test-key", session: session)
        let chapters = try await engine.generate(from: segments)

        #expect(chapters.count == 2)
        #expect(chapters[0].start == 0)
        #expect(chapters[0].title == "イントロ")
        #expect(chapters[1].start == 60)
        #expect(chapters[1].title == "まとめ")
        #expect(chapters.allSatisfy { $0.source == .generated })
    }

    @Test
    func makeLinesPreservesFullTextAndBreaksOnGapsAndSentences() {
        let segments = [
            // Continuous speech, no terminal punctuation → merges into one line.
            TranscriptSegment(start: 0, end: 2, text: "今日は"),
            TranscriptSegment(start: 2, end: 4, text: "ポッドキャストの話"),
            // Sentence end → closes the line here.
            TranscriptSegment(start: 4, end: 6, text: "を始めます。"),
            // Long pause (≥8s) → next line starts fresh at 30s.
            TranscriptSegment(start: 30, end: 33, text: "次のトピックです"),
        ]
        let lines = GeminiChapterEngine.makeLines(from: segments)

        #expect(lines.count == 2)
        #expect(lines[0].start == 0)
        // Full text is preserved (no 80-char truncation), CJK joined without spaces.
        #expect(lines[0].text == "今日はポッドキャストの話を始めます。")
        #expect(lines[1].start == 30)
        #expect(lines[1].text == "次のトピックです")
    }

    @Test
    func throwsOnMissingAPIKey() async {
        let engine = GeminiChapterEngine(apiKey: "", session: makeStubSession())
        await #expect(throws: GeminiChapterEngine.EngineError.self) {
            _ = try await engine.generate(from: segments)
        }
    }

    @Test
    func throwsOnHTTPError() async {
        let session = makeStubSession()
        GeminiStubURLProtocol.responder = { _ in (429, Data(#"{"error":"rate limited"}"#.utf8)) }
        let engine = GeminiChapterEngine(apiKey: "k", session: session)
        await #expect(throws: GeminiChapterEngine.EngineError.self) {
            _ = try await engine.generate(from: segments)
        }
    }
}

// MARK: - GeminiStubURLProtocol

/// Dedicated stub so Gemini tests never share global responder state with the
/// Auphonic suite (both run under the parallel test runner).
final class GeminiStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responder: (@Sendable (RecordedRequest) throws -> (Int, Data))?

    struct RecordedRequest: Sendable {
        var url: URL?
        var httpMethod: String?
        var allHTTPHeaderFields: [String: String]?
        var bodyData: Data?
        func value(forHTTPHeaderField field: String) -> String? {
            allHTTPHeaderFields?[field] ?? allHTTPHeaderFields?[field.lowercased()]
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let recorded = RecordedRequest(
            url: request.url,
            httpMethod: request.httpMethod,
            allHTTPHeaderFields: request.allHTTPHeaderFields,
            bodyData: request.httpBodyStream.flatMap { Self.drain($0) } ?? request.httpBody
        )
        do {
            guard let responder = Self.responder else {
                throw GeminiChapterEngine.EngineError.emptyResponse
            }
            let (status, body) = try responder(recorded)
            let resp = HTTPURLResponse(
                url: request.url ?? URL(string: "about:blank")!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": "\(body.count)"]
            )!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func drain(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var buf = Data()
        let chunk = 64 * 1024
        var bytes = [UInt8](repeating: 0, count: chunk)
        while stream.hasBytesAvailable {
            let n = stream.read(&bytes, maxLength: chunk)
            if n <= 0 { break }
            buf.append(bytes, count: n)
        }
        return buf
    }
}

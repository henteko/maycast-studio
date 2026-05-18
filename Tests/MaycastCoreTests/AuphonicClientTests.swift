import Testing
import Foundation
@testable import MaycastCore

@Suite("AuphonicClient (URLProtocol stub)", .serialized)
struct AuphonicClientTests {
    /// Build a URLSession whose only protocol class is `StubURLProtocol`. All
    /// requests issued via the resulting session land in the global
    /// `StubURLProtocol.responder` closure, which the tests configure.
    private func makeStubSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeTempFile(named name: String, contents: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("maycast-auphonic-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - createProduction

    @Test
    func createProductionSendsPayloadAndReturnsUUID() async throws {
        let session = makeStubSession()
        StubURLProtocol.responder = { req in
            #expect(req.httpMethod == "POST")
            #expect(req.url?.path == "/api/productions.json")
            #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
            #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
            // Body should decode as a ProductionPayload.
            let data = req.bodyData ?? Data()
            let decoded = try JSONDecoder().decode(Auphonic.ProductionPayload.self, from: data)
            #expect(decoded.isMultitrack == true)
            #expect(decoded.multiInputFiles.count == 2)
            #expect(decoded.algorithms.loudnessTarget == -16)
            // Reply with an envelope-wrapped production.
            let json = """
            {"status_code": 200, "data": {"uuid": "abc-123", "status": 1, "status_string": "Waiting"}}
            """
            return (200, Data(json.utf8))
        }
        let client = AuphonicClient(apiKey: "test-key", session: session)
        let payload = Auphonic.ProductionPayload(
            isMultitrack: true,
            multiInputFiles: [
                Auphonic.MultiInputFile(type: "multitrack", id: "host"),
                Auphonic.MultiInputFile(type: "multitrack", id: "guest"),
            ],
            algorithms: Auphonic.Algorithms(loudnessTarget: -16),
            outputFiles: [Auphonic.OutputFile(format: "wav")]
        )
        let response = try await client.createProduction(payload: payload)
        #expect(response.uuid == "abc-123")
        #expect(response.status == 1)
    }

    @Test
    func createProductionTreatsEmptyErrorMessageAsSuccess() async throws {
        // Auphonic echoes back `error_message: ""` on success — must not be
        // mistaken for an actual API error.
        let session = makeStubSession()
        StubURLProtocol.responder = { _ in
            let json = #"{"status_code":200,"error_message":"","data":{"uuid":"u1","status":1}}"#
            return (200, Data(json.utf8))
        }
        let client = AuphonicClient(apiKey: "k", session: session)
        let payload = Auphonic.ProductionPayload(
            isMultitrack: true,
            multiInputFiles: [],
            algorithms: Auphonic.Algorithms(),
            outputFiles: []
        )
        let response = try await client.createProduction(payload: payload)
        #expect(response.uuid == "u1")
    }

    @Test
    func createProductionSurfacesApiErrorMessage() async throws {
        let session = makeStubSession()
        StubURLProtocol.responder = { _ in
            let json = #"{"status_code": 400, "error_message": "Invalid algorithms"}"#
            return (400, Data(json.utf8))
        }
        let client = AuphonicClient(apiKey: "k", session: session)
        let payload = Auphonic.ProductionPayload(
            isMultitrack: true,
            multiInputFiles: [],
            algorithms: Auphonic.Algorithms(),
            outputFiles: []
        )
        await #expect(throws: AuphonicError.self) {
            _ = try await client.createProduction(payload: payload)
        }
    }

    // MARK: - upload

    @Test
    func uploadTrackUsesTrackIDDerivedFilename() async throws {
        // Even when the source file shares a basename with another track (the
        // typical Maycast bundle layout where every generation is e.g.
        // `001_import.wav`), the uploaded filename must be derived from the
        // track ID so Auphonic doesn't deduplicate the second upload against
        // the first.
        let session = makeStubSession()
        let file = try makeTempFile(named: "001_import.wav", contents: "FAKE-WAV-DATA-host")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        StubURLProtocol.responder = { req in
            #expect(req.httpMethod == "POST")
            #expect(req.url?.path == "/api/production/p1/upload.json")
            let ct = req.value(forHTTPHeaderField: "Content-Type") ?? ""
            #expect(ct.starts(with: "multipart/form-data; boundary="))
            let body = String(data: req.bodyData ?? Data(), encoding: .utf8) ?? ""
            #expect(body.contains("name=\"host\""))
            #expect(body.contains("filename=\"host.wav\""))
            #expect(!body.contains("filename=\"001_import.wav\""))
            #expect(body.contains("FAKE-WAV-DATA-host"))
            return (200, Data("{\"status_code\":200,\"data\":{}}".utf8))
        }
        let client = AuphonicClient(apiKey: "k", session: session)
        try await client.uploadTrack(uuid: "p1", trackID: "host", fileURL: file)
    }

    @Test
    func uploadThrowsOnMissingFile() async throws {
        let session = makeStubSession()
        let client = AuphonicClient(apiKey: "k", session: session)
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString).wav")
        await #expect(throws: AuphonicError.self) {
            try await client.uploadTrack(uuid: "p1", trackID: "host", fileURL: missing)
        }
    }

    // MARK: - polling

    @Test
    func pollUntilDoneReturnsWhenStatusIsDone() async throws {
        let session = makeStubSession()
        let states = StateBox<[Int]>([1, 1, Auphonic.Status.done])
        StubURLProtocol.responder = { _ in
            let next = states.popFirst() ?? Auphonic.Status.done
            let json = #"{"status_code":200,"data":{"uuid":"u1","status":\#(next),"status_string":"running"}}"#
            return (200, Data(json.utf8))
        }
        let client = AuphonicClient(apiKey: "k", session: session)
        let ticks = StateBox<Int>(0)
        let result = try await client.pollUntilDone(uuid: "u1", intervalSeconds: 0.01) { _ in
            ticks.mutate { $0 += 1 }
        }
        #expect(result.status == Auphonic.Status.done)
        #expect(ticks.value >= 3)
    }

    @Test
    func pollUntilDoneThrowsOnTerminalErrorStatus() async throws {
        let session = makeStubSession()
        StubURLProtocol.responder = { _ in
            let json = #"{"status_code":200,"data":{"uuid":"u1","status":9,"status_string":"Error","error_message":"boom"}}"#
            return (200, Data(json.utf8))
        }
        let client = AuphonicClient(apiKey: "k", session: session)
        await #expect(throws: AuphonicError.self) {
            _ = try await client.pollUntilDone(uuid: "u1", intervalSeconds: 0.01)
        }
    }

    // MARK: - delete

    @Test
    func deleteProductionAcceptsBoth2xxAnd404() async throws {
        let session = makeStubSession()
        let calls = StateBox<Int>(0)
        StubURLProtocol.responder = { _ in
            calls.mutate { $0 += 1 }
            return (calls.value == 1 ? 204 : 404, Data())
        }
        let client = AuphonicClient(apiKey: "k", session: session)
        try await client.deleteProduction(uuid: "u1")  // 204
        try await client.deleteProduction(uuid: "u1")  // 404 — still fine
    }

    @Test
    func deleteProductionThrowsOnOtherErrors() async throws {
        let session = makeStubSession()
        StubURLProtocol.responder = { _ in (500, Data()) }
        let client = AuphonicClient(apiKey: "k", session: session)
        await #expect(throws: AuphonicError.self) {
            try await client.deleteProduction(uuid: "u1")
        }
    }

    // MARK: - download

    @Test
    func downloadWritesBytesAndReportsProgress() async throws {
        let session = makeStubSession()
        let payload = Data(repeating: 0xAB, count: 128 * 1024)  // 128KB
        StubURLProtocol.responder = { _ in
            (200, payload)
        }
        let client = AuphonicClient(apiKey: "k", session: session)
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("auphonic-dl-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: dest) }
        let progress = StateBox<Double>(0)
        try await client.download(
            from: URL(string: "https://auphonic.test/dl")!,
            to: dest
        ) { p in progress.mutate { $0 = p } }
        let written = try Data(contentsOf: dest)
        #expect(written == payload)
        #expect(progress.value >= 0.99)
    }
}

// MARK: - StubURLProtocol

/// URLProtocol subclass that captures requests and synthesises responses
/// from a globally-set closure. Used to drive `AuphonicClient` under test
/// without ever touching the network.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    /// Closure that takes a captured `RecordedRequest` and returns (statusCode, body).
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
                throw AuphonicError.unexpected("StubURLProtocol.responder not set")
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

// MARK: - StateBox

/// Mutable shared state across @Sendable closures and async contexts (tests only).
final class StateBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ initial: T) { _value = initial }
    var value: T {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
    func mutate(_ block: (inout T) -> Void) {
        lock.lock(); defer { lock.unlock() }
        block(&_value)
    }
    /// Mutate-and-take-first for an array-typed box. Returns nil when empty.
    func popFirst<U>() -> U? where T == [U] {
        lock.lock(); defer { lock.unlock() }
        guard !_value.isEmpty else { return nil }
        return _value.removeFirst()
    }
}

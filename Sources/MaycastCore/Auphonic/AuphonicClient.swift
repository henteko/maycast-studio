import Foundation

/// Async wrapper around the Auphonic Multitrack API.
///
/// Designed for cancellation: every async method respects `Task.isCancelled`,
/// and `pollUntilDone` exits promptly on cancellation so the caller can
/// dismiss the operation without waiting for the next poll tick.
///
/// Uploads stream from disk via a temp multipart file, so memory usage is
/// bounded regardless of audio file size.
public actor AuphonicClient {
    private let apiKey: String
    private let baseURL: URL
    private let session: URLSession

    public init(apiKey: String, baseURL: URL = Auphonic.baseURL, session: URLSession? = nil) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            // Per-request idle timeout. Multipart uploads of multi-hundred-MB
            // tracks routinely stall for tens of seconds between TCP windows.
            config.timeoutIntervalForRequest = 120
            // Overall timeout for the entire upload / download. Auphonic's
            // own production timeout is around 30 minutes, so we match.
            config.timeoutIntervalForResource = 30 * 60
            // Don't fail the request immediately if the network briefly drops
            // (e.g. Wi-Fi roaming) — wait for it to come back.
            config.waitsForConnectivity = true
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - Production lifecycle

    public func createProduction(payload: Auphonic.ProductionPayload) async throws -> Auphonic.ProductionResponse {
        let body = try JSONEncoder().encode(payload)
        var req = makeRequest("/api/productions.json", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        return try await requestEnvelope(req)
    }

    public func startProduction(uuid: String) async throws -> Auphonic.ProductionResponse {
        let req = makeRequest("/api/production/\(uuid)/start.json", method: "POST")
        return try await requestEnvelope(req)
    }

    public func getProduction(uuid: String) async throws -> Auphonic.ProductionResponse {
        let req = makeRequest("/api/production/\(uuid).json", method: "GET")
        return try await requestEnvelope(req)
    }

    public func deleteProduction(uuid: String) async throws {
        let req = makeRequest("/api/production/\(uuid).json", method: "DELETE")
        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw AuphonicError.unexpected("DELETE: non-HTTP response")
        }
        if !(200..<300).contains(http.statusCode) && http.statusCode != 404 {
            throw AuphonicError.http(status: http.statusCode, body: nil)
        }
    }

    // MARK: - Upload

    /// Uploads a single track file as multipart/form-data. The body is
    /// streamed from a temp file so memory usage stays bounded.
    public func uploadTrack(uuid: String, trackID: String, fileURL: URL) async throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw AuphonicError.fileNotFound(fileURL)
        }

        let boundary = "----Maycast-\(UUID().uuidString)"
        let bodyFile = try buildMultipartBody(
            boundary: boundary,
            fieldName: trackID,
            file: fileURL
        )
        defer { try? FileManager.default.removeItem(at: bodyFile) }

        var req = makeRequest("/api/production/\(uuid)/upload.json", method: "POST")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        try await uploadWithRetry(req: req, bodyFile: bodyFile)
    }

    /// Perform a multipart upload with bounded retries. Retries cover transient
    /// transport-level errors (refused connections, dropped sockets, DNS
    /// flakes) and 5xx replies — Auphonic occasionally returns these mid-batch
    /// for large uploads. 4xx errors and other non-transient failures bubble
    /// up immediately.
    private func uploadWithRetry(req: URLRequest, bodyFile: URL, maxRetries: Int = 2) async throws {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.upload(for: req, fromFile: bodyFile)
                guard let http = response as? HTTPURLResponse else {
                    throw AuphonicError.unexpected("upload: non-HTTP response")
                }
                if (200..<300).contains(http.statusCode) {
                    return
                }
                if http.statusCode >= 500, attempt < maxRetries {
                    attempt += 1
                    try await sleep(seconds: Double(5 * attempt))
                    continue
                }
                throw AuphonicError.http(status: http.statusCode, body: String(data: data, encoding: .utf8))
            } catch let err as URLError {
                if attempt < maxRetries && Self.isRetryableURLError(err) {
                    attempt += 1
                    try await sleep(seconds: Double(5 * attempt))
                    continue
                }
                throw err
            }
        }
    }

    private static func isRetryableURLError(_ error: URLError) -> Bool {
        switch error.code {
        case .cannotConnectToHost,       // -1004
             .timedOut,                  // -1001
             .networkConnectionLost,     // -1005
             .dnsLookupFailed,           // -1006
             .notConnectedToInternet,    // -1009
             .cannotFindHost:            // -1003 (rare here but harmless to retry)
            return true
        default:
            return false
        }
    }

    // MARK: - Polling

    /// Polls until the production reaches `STATUS_DONE` or a terminal error.
    /// - Parameters:
    ///   - uuid: production identifier
    ///   - intervalSeconds: time between polls (default 5s — Auphonic recommends ≥ 5s)
    ///   - timeoutSeconds: maximum wall-clock time to wait (default 30 min)
    ///   - onTick: receives each non-error `ProductionResponse`. Use it to
    ///     update the UI with the latest `status_string`.
    public func pollUntilDone(
        uuid: String,
        intervalSeconds: Double = 5,
        timeoutSeconds: Double = 30 * 60,
        onTick: @Sendable @escaping (Auphonic.ProductionResponse) -> Void = { _ in }
    ) async throws -> Auphonic.ProductionResponse {
        let start = Date()
        var consecutiveErrors = 0
        while true {
            try Task.checkCancellation()
            if Date().timeIntervalSince(start) > timeoutSeconds {
                throw AuphonicError.timeout(uuid: uuid, waited: Date().timeIntervalSince(start))
            }
            let production: Auphonic.ProductionResponse
            do {
                production = try await getProduction(uuid: uuid)
                consecutiveErrors = 0
            } catch let e as AuphonicError {
                if case .http(let status, _) = e, status >= 500, consecutiveErrors < 3 {
                    consecutiveErrors += 1
                    try await sleep(seconds: intervalSeconds)
                    continue
                }
                throw e
            }

            onTick(production)
            if production.status == Auphonic.Status.done {
                return production
            }
            if Auphonic.Status.terminalErrors.contains(production.status) {
                throw AuphonicError.productionFailed(
                    uuid: uuid,
                    status: production.status,
                    statusString: production.statusString,
                    error: production.errorMessage
                )
            }
            try await sleep(seconds: intervalSeconds)
        }
    }

    // MARK: - Download

    /// Downloads the URL (with the API key attached) to `destination` while
    /// reporting per-byte progress in the 0–1 range. Uses streaming reads so
    /// large files don't need to fit in memory.
    public func download(
        from url: URL,
        to destination: URL,
        onProgress: @Sendable @escaping (Double) -> Void = { _ in }
    ) async throws {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (asyncBytes, response) = try await session.bytes(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw AuphonicError.unexpected("download: non-HTTP response")
        }
        if !(200..<300).contains(http.statusCode) {
            throw AuphonicError.http(status: http.statusCode, body: nil)
        }

        let totalBytes = http.expectedContentLength
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        fm.createFile(atPath: destination.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: destination) else {
            throw AuphonicError.download(url: url, underlying: nil)
        }
        defer { try? handle.close() }

        var buffered = Data()
        buffered.reserveCapacity(64 * 1024)
        var receivedBytes: Int64 = 0
        var lastProgress: Double = -1

        for try await byte in asyncBytes {
            try Task.checkCancellation()
            buffered.append(byte)
            if buffered.count >= 64 * 1024 {
                try handle.write(contentsOf: buffered)
                receivedBytes += Int64(buffered.count)
                buffered.removeAll(keepingCapacity: true)
                if totalBytes > 0 {
                    let p = min(1.0, Double(receivedBytes) / Double(totalBytes))
                    if p - lastProgress >= 0.01 {
                        lastProgress = p
                        onProgress(p)
                    }
                }
            }
        }
        if !buffered.isEmpty {
            try handle.write(contentsOf: buffered)
            receivedBytes += Int64(buffered.count)
        }
        onProgress(1.0)
    }

    // MARK: - Helpers

    private func makeRequest(_ path: String, method: String) -> URLRequest {
        let url = baseURL.appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return req
    }

    private func requestEnvelope(_ req: URLRequest) async throws -> Auphonic.ProductionResponse {
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw AuphonicError.unexpected("non-HTTP response")
        }
        if !(200..<300).contains(http.statusCode) {
            // Try to surface the API's error_message if present.
            if let envelope = try? JSONDecoder().decode(
                Auphonic.Envelope<Auphonic.ProductionResponse>.self, from: data
            ), let msg = envelope.errorMessage, !msg.isEmpty {
                throw AuphonicError.apiError(message: msg, statusCode: http.statusCode)
            }
            throw AuphonicError.http(status: http.statusCode, body: String(data: data, encoding: .utf8))
        }
        do {
            let envelope = try JSONDecoder().decode(
                Auphonic.Envelope<Auphonic.ProductionResponse>.self,
                from: data
            )
            // Auphonic returns `error_message: ""` (empty string) on success —
            // treat empty as "no error" so we don't misreport HTTP 200.
            if let msg = envelope.errorMessage, !msg.isEmpty {
                throw AuphonicError.apiError(message: msg, statusCode: http.statusCode)
            }
            guard let payload = envelope.data else {
                throw AuphonicError.unexpected("envelope.data was nil")
            }
            return payload
        } catch let e as AuphonicError {
            throw e
        } catch {
            throw AuphonicError.decoding(underlying: error)
        }
    }

    private func buildMultipartBody(
        boundary: String,
        fieldName: String,
        file: URL
    ) throws -> URL {
        let tmpDir = FileManager.default.temporaryDirectory
        let tmpURL = tmpDir.appendingPathComponent("auphonic-upload-\(UUID().uuidString).bin")
        FileManager.default.createFile(atPath: tmpURL.path, contents: nil)
        guard let out = try? FileHandle(forWritingTo: tmpURL) else {
            throw AuphonicError.unexpected("could not open temp upload file")
        }
        defer { try? out.close() }

        // Use the field name (= track ID) as the upload filename so that
        // multiple speakers whose source files share a basename (e.g. every
        // generation in Maycast bundles is `001_import.wav`) don't collide
        // server-side. Auphonic uses the multipart filename to identify the
        // uploaded asset; without this fix the second upload silently
        // overwrites the first.
        let ext = file.pathExtension.isEmpty ? "wav" : file.pathExtension.lowercased()
        let filename = "\(fieldName).\(ext)"
        let mimeType = mime(forExtension: ext)

        var header = ""
        header += "--\(boundary)\r\n"
        header += "Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(filename)\"\r\n"
        header += "Content-Type: \(mimeType)\r\n\r\n"
        try out.write(contentsOf: Data(header.utf8))

        // Stream the file contents in 256 KB chunks.
        let inHandle = try FileHandle(forReadingFrom: file)
        defer { try? inHandle.close() }
        let chunkSize = 256 * 1024
        while true {
            let chunk = try inHandle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            try out.write(contentsOf: chunk)
        }

        let footer = "\r\n--\(boundary)--\r\n"
        try out.write(contentsOf: Data(footer.utf8))

        return tmpURL
    }

    private func mime(forExtension ext: String) -> String {
        switch ext {
        case "wav": return "audio/wav"
        case "flac": return "audio/flac"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "aac": return "audio/aac"
        case "aiff", "aif": return "audio/aiff"
        default: return "application/octet-stream"
        }
    }

    private func sleep(seconds: Double) async throws {
        let nanos = UInt64(max(0, seconds) * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanos)
    }
}

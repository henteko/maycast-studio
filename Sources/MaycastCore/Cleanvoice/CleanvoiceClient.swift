import Foundation

/// Async wrapper around the Cleanvoice v2 REST API.
///
/// Local files go up in two steps — `POST /v2/upload?filename=…` returns a
/// signed URL, the file is `PUT` there — and the signed URL minus its query
/// string is what `POST /v2/edits` references. Edits run asynchronously and
/// are polled via `GET /v2/edits/{id}`.
///
/// Like `AuphonicClient`, every method respects cancellation and uploads
/// stream from disk so memory stays bounded.
public actor CleanvoiceClient {
    private let apiKey: String
    private let baseURL: URL
    private let session: URLSession

    public init(apiKey: String, baseURL: URL = Cleanvoice.baseURL, session: URLSession? = nil) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            // Same rationale as AuphonicClient: long multipart / PUT uploads
            // stall between TCP windows, and Wi-Fi blips shouldn't fail a run.
            config.timeoutIntervalForRequest = 120
            config.timeoutIntervalForResource = 60 * 60
            config.waitsForConnectivity = true
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - Upload

    /// Upload a local file and return the URL to reference in `createEdit`.
    /// `filename` is what Cleanvoice stores (and names its output after), so
    /// callers pass a track-derived name to keep speakers distinguishable.
    public func upload(fileURL: URL, filename: String) async throws -> String {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw CleanvoiceError.fileNotFound(fileURL)
        }
        let signed = try await requestUploadURL(filename: filename)
        guard let signedURL = URL(string: signed) else {
            throw CleanvoiceError.unexpected("invalid signed upload URL: \(signed)")
        }

        var put = URLRequest(url: signedURL)
        put.httpMethod = "PUT"
        put.setValue(Self.mime(forExtension: fileURL.pathExtension.lowercased()), forHTTPHeaderField: "Content-Type")
        try await uploadWithRetry(req: put, file: fileURL)

        // The edit references the object without its signature.
        return Self.stripQuery(signed)
    }

    func requestUploadURL(filename: String) async throws -> String {
        var comps = URLComponents(url: baseURL.appendingPathComponent("/v2/upload"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "filename", value: filename)]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        let response: Cleanvoice.UploadURLResponse = try await requestJSON(req)
        return response.signedUrl
    }

    /// PUT with bounded retries for transient transport errors and 5xx.
    private func uploadWithRetry(req: URLRequest, file: URL, maxRetries: Int = 2) async throws {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.upload(for: req, fromFile: file)
                guard let http = response as? HTTPURLResponse else {
                    throw CleanvoiceError.unexpected("upload: non-HTTP response")
                }
                if (200..<300).contains(http.statusCode) { return }
                if http.statusCode >= 500, attempt < maxRetries {
                    attempt += 1
                    try await sleep(seconds: Double(5 * attempt))
                    continue
                }
                throw CleanvoiceError.http(status: http.statusCode, body: String(data: data, encoding: .utf8))
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

    // MARK: - Edits

    public func createEdit(_ request: Cleanvoice.CreateEditRequest) async throws -> String {
        var req = makeRequest("/v2/edits", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(request)
        let response: Cleanvoice.CreateEditResponse = try await requestJSON(req)
        return response.id
    }

    public func getEdit(id: String) async throws -> Cleanvoice.EditResponse {
        try await requestJSON(makeRequest("/v2/edits/\(id)", method: "GET"))
    }

    /// Polls until the edit reaches `SUCCESS` (returned) or `FAILURE` (thrown).
    /// Cleanvoice asks for ≥ 5 s between polls and suggests waiting before
    /// the first one, hence `initialDelaySeconds`.
    public func pollUntilDone(
        id: String,
        initialDelaySeconds: Double = 15,
        intervalSeconds: Double = 10,
        timeoutSeconds: Double = 60 * 60,
        onTick: @Sendable @escaping (Cleanvoice.EditResponse) -> Void = { _ in }
    ) async throws -> Cleanvoice.EditResponse {
        let start = Date()
        var consecutiveErrors = 0
        try await sleep(seconds: initialDelaySeconds)
        while true {
            try Task.checkCancellation()
            if Date().timeIntervalSince(start) > timeoutSeconds {
                throw CleanvoiceError.timeout(editID: id, waited: Date().timeIntervalSince(start))
            }
            let edit: Cleanvoice.EditResponse
            do {
                edit = try await getEdit(id: id)
                consecutiveErrors = 0
            } catch let e as CleanvoiceError {
                if case .http(let status, _) = e, status >= 500, consecutiveErrors < 3 {
                    consecutiveErrors += 1
                    try await sleep(seconds: intervalSeconds)
                    continue
                }
                throw e
            }

            onTick(edit)
            if edit.status == Cleanvoice.Status.success {
                // The result can lag the status by a poll; keep waiting until
                // the download URL is actually there.
                if !(edit.result?.downloadURL?.values.isEmpty ?? true) { return edit }
            } else if edit.status == Cleanvoice.Status.failure {
                throw CleanvoiceError.editFailed(editID: id, message: edit.result?.error)
            }
            try await sleep(seconds: intervalSeconds)
        }
    }

    // MARK: - Download

    /// Downloads a result URL to `destination`, reporting progress in 0–1.
    /// Result URLs are pre-signed CDN links, so no API key is attached.
    public func download(
        from url: URL,
        to destination: URL,
        onProgress: @Sendable @escaping (Double) -> Void = { _ in }
    ) async throws {
        let (asyncBytes, response) = try await session.bytes(for: URLRequest(url: url))
        guard let http = response as? HTTPURLResponse else {
            throw CleanvoiceError.unexpected("download: non-HTTP response")
        }
        if !(200..<300).contains(http.statusCode) {
            throw CleanvoiceError.http(status: http.statusCode, body: nil)
        }

        let totalBytes = http.expectedContentLength
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        fm.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var buffered = Data()
        buffered.reserveCapacity(64 * 1024)
        var receivedBytes: Int64 = 0
        var lastProgress: Double = -1
        for try await byte in asyncBytes {
            buffered.append(byte)
            if buffered.count >= 64 * 1024 {
                try Task.checkCancellation()
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
        }
        onProgress(1.0)
    }

    // MARK: - Helpers

    private func makeRequest(_ path: String, method: String) -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        return req
    }

    private func requestJSON<T: Decodable>(_ req: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw CleanvoiceError.unexpected("non-HTTP response")
        }
        if !(200..<300).contains(http.statusCode) {
            throw CleanvoiceError.http(status: http.statusCode, body: Self.errorDetail(from: data))
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw CleanvoiceError.decoding(underlying: error)
        }
    }

    /// Surface `detail` / `message` / `error` from an error body when present,
    /// otherwise the raw body.
    static func errorDetail(from data: Data) -> String? {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["detail", "message", "error"] {
                if let s = obj[key] as? String, !s.isEmpty { return s }
            }
        }
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty ?? true) ? nil : text
    }

    static func stripQuery(_ urlString: String) -> String {
        urlString.split(separator: "?", maxSplits: 1).first.map(String.init) ?? urlString
    }

    private static func isRetryableURLError(_ error: URLError) -> Bool {
        switch error.code {
        case .cannotConnectToHost, .timedOut, .networkConnectionLost,
             .dnsLookupFailed, .notConnectedToInternet, .cannotFindHost:
            return true
        default:
            return false
        }
    }

    static func mime(forExtension ext: String) -> String {
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
        guard seconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

import Testing
import Foundation
@testable import MaycastCore

/// `CleanvoiceClient` + `CleanvoicePolishEngine` against a stubbed network.
/// Polish is GUI-only (no CLI surface), so the full upload → edit → poll →
/// download → generation pipeline is pinned here instead of in an E2E test.
@Suite("Cleanvoice (URLProtocol stub)", .serialized)
struct CleanvoiceClientTests {
    private func makeStubSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CleanvoiceStubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("maycast-cleanvoice-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Episode with the given tracks, each with a 2s silent first generation.
    private func makeEpisode(at workspace: URL, trackIDs: [String], video: Bool = false) throws -> URL {
        let episodeURL = workspace.appendingPathComponent("ep01.maycast")
        var bundle = try EpisodeBundle.create(at: episodeURL)
        let fm = FileManager.default
        for id in trackIDs {
            let rel = "intermediate/\(id)/001_import.wav"
            let url = episodeURL.appendingPathComponent(rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try AudioIO.writeWAV(AudioIO.silence(duration: 2.0, sampleRate: 48000, channelCount: 1), to: url)
            var videoSource: String? = nil
            if video {
                videoSource = "sources/\(id).mp4"
                let src = episodeURL.appendingPathComponent(videoSource!)
                try fm.createDirectory(at: src.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("VIDEO".utf8).write(to: src)
            }
            let identity = Arrangement.single(sourceDuration: 2.0)
            bundle.upsertTrack(Track(
                id: id,
                source: videoSource ?? "sources/\(id).wav",
                current: rel,
                history: [rel],
                videoSource: videoSource,
                videoEdit: video ? identity : nil,
                videoEditHistory: video ? [identity] : nil
            ))
        }
        try bundle.save()
        return episodeURL
    }

    private func wavData(duration: Double) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cv-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try AudioIO.writeWAV(AudioIO.silence(duration: duration, sampleRate: 48000, channelCount: 1), to: url)
        return try Data(contentsOf: url)
    }

    /// ZIP the given (name → data) entries with /usr/bin/zip.
    private func zipData(_ entries: [String: Data]) throws -> Data {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for (name, data) in entries {
            try data.write(to: dir.appendingPathComponent(name))
        }
        let zip = dir.appendingPathComponent("out.zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.currentDirectoryURL = dir
        p.arguments = ["-q", zip.path] + entries.keys.sorted()
        try p.run()
        p.waitUntilExit()
        return try Data(contentsOf: zip)
    }

    private func json(_ s: String) -> Data { Data(s.utf8) }

    // MARK: - Client

    @Test
    func uploadRequestsSignedURLThenPutsAndStripsQuery() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("001_import.wav")
        try Data("FAKE".utf8).write(to: file)

        let seen = StateBox<[String]>([])
        CleanvoiceStubURLProtocol.responder = { req in
            seen.mutate { $0.append("\(req.httpMethod ?? "") \(req.url?.host ?? "")\(req.url?.path ?? "")") }
            if req.url?.path == "/v2/upload" {
                #expect(req.httpMethod == "POST")
                #expect(req.value(forHTTPHeaderField: "X-API-Key") == "cv-key")
                #expect(req.url?.query == "filename=host.wav")
                return (200, self.json(#"{"signedUrl":"https://storage.example.com/u/host.wav?X-Sig=abc&X-Exp=1"}"#))
            }
            #expect(req.httpMethod == "PUT")
            #expect(req.value(forHTTPHeaderField: "Content-Type") == "audio/wav")
            return (200, Data())
        }
        let client = CleanvoiceClient(apiKey: "cv-key", session: makeStubSession())
        let ref = try await client.upload(fileURL: file, filename: "host.wav")
        #expect(ref == "https://storage.example.com/u/host.wav")
        #expect(seen.value == ["POST api.cleanvoice.ai/v2/upload", "PUT storage.example.com/u/host.wav"])
    }

    @Test
    func httpErrorSurfacesDetail() async throws {
        CleanvoiceStubURLProtocol.responder = { _ in (401, self.json(#"{"detail":"Invalid API key"}"#)) }
        let client = CleanvoiceClient(apiKey: "bad", session: makeStubSession())
        do {
            _ = try await client.getEdit(id: "x")
            Issue.record("expected an error")
        } catch let e as CleanvoiceError {
            #expect(e.description == "Cleanvoice API: HTTP 401 — Invalid API key")
        }
    }

    @Test
    func configEncodesSnakeCaseAndOmitsUnset() throws {
        var options = CleanvoicePolishOptions.defaults
        options.normalize = false
        options.muteEdits = true
        let data = try JSONEncoder().encode(options.config())
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["long_silences"] as? Bool == true)
        #expect(obj["mouth_sounds"] as? Bool == true)
        #expect(obj["remove_noise"] as? Bool == true)
        #expect(obj["breath"] as? String == "natural")
        #expect(obj["muted"] as? Bool == true)
        #expect(obj["export_format"] as? String == "wav")
        #expect(obj["merge"] as? Bool == false)
        #expect(obj["target_lufs"] == nil)   // only sent with normalize
        #expect(obj["export_timestamps"] == nil)  // only when a video track needs the cut list
        let withCuts = try JSONSerialization.jsonObject(with: JSONEncoder().encode(options.config(exportTimestamps: true))) as? [String: Any]
        #expect(withCuts?["export_timestamps"] as? Bool == true)
    }

    @Test
    func editResponseDecodesProgressSuccessAndOddShapes() throws {
        let progress = try JSONDecoder().decode(Cleanvoice.EditResponse.self, from: json(
            #"{"status":"PREPROCESSING","result":{"done":13.571428571428571,"total":100,"state":"PREPROCESSING","phase":0,"step":4,"substep":3,"job_name":"9vWk4C4_ho and 1 more"},"task_id":"t","eta":{"queue":"priority"}}"#
        ))
        #expect(progress.stageDescription == "PREPROCESSING 14%")

        let single = try JSONDecoder().decode(Cleanvoice.EditResponse.self, from: json(
            #"{"task_id":"e1","status":"SUCCESS","result":{"download_url":"https://cdn/x.zip","merged_audio_url":[],"statistics":{"BREATH":2}}}"#
        ))
        #expect(single.result?.downloadURL?.values == ["https://cdn/x.zip"])
        #expect(single.result?.mergedAudioURL?.values == [])

        let many = try JSONDecoder().decode(Cleanvoice.EditResponse.self, from: json(
            #"{"status":"SUCCESS","result":{"download_url":["https://cdn/a.wav","https://cdn/b.wav"]}}"#
        ))
        #expect(many.result?.downloadURL?.values.count == 2)

        // Failure payloads aren't documented; a non-object result must not break decoding.
        let failed = try JSONDecoder().decode(Cleanvoice.EditResponse.self, from: json(
            #"{"status":"FAILURE","result":"something went wrong"}"#
        ))
        #expect(failed.status == "FAILURE")
        #expect(failed.result == nil)
    }

    // MARK: - Engine

    @Test
    func engineMultitrackZipWritesOneGenerationPerSpeaker() async throws {
        let workspace = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let episode = try makeEpisode(at: workspace, trackIDs: ["host", "guest"])
        let zip = try zipData([
            // Layout observed from the live API: Cleanvoice prefixes stored
            // uploads with a random token and suffixes outputs with `_clean`.
            "9vWk4C4_host_clean.wav": try wavData(duration: 1.5),
            "AffifsL_guest_clean.wav": try wavData(duration: 1.25),
        ])

        let polls = StateBox(0)
        CleanvoiceStubURLProtocol.responder = { req in
            let path = req.url?.path ?? ""
            switch (req.httpMethod ?? "", req.url?.host ?? "", path) {
            case ("POST", "api.cleanvoice.ai", "/v2/upload"):
                let name = req.url?.query?.replacingOccurrences(of: "filename=", with: "") ?? ""
                return (200, self.json(#"{"signedUrl":"https://storage.example.com/u/\#(name)?sig=1"}"#))
            case ("PUT", "storage.example.com", _):
                return (200, Data())
            case ("POST", "api.cleanvoice.ai", "/v2/edits"):
                let body = try #require(try JSONSerialization.jsonObject(with: req.bodyData ?? Data()) as? [String: Any])
                let input = try #require(body["input"] as? [String: Any])
                #expect(input["files"] as? [String] == [
                    "https://storage.example.com/u/host.wav",
                    "https://storage.example.com/u/guest.wav",
                ])
                #expect(input["upload_type"] as? String == "multitrack")
                let config = try #require(input["config"] as? [String: Any])
                #expect(config["muted"] as? Bool == false)  // audio-only: real cuts
                return (200, self.json(#"{"id":"edit_1"}"#))
            case ("GET", "api.cleanvoice.ai", "/v2/edits/edit_1"):
                polls.mutate { $0 += 1 }
                if polls.value == 1 {
                    return (200, self.json(#"{"status":"EDITING","result":{"job_name":"x_host and 1 more","done":50,"total":100}}"#))
                }
                return (200, self.json(#"{"status":"SUCCESS","result":{"download_url":"https://cdn.example.com/edit_1.zip"}}"#))
            case ("GET", "cdn.example.com", "/edit_1.zip"):
                return (200, zip)
            default:
                Issue.record("unexpected request \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return (404, Data())
            }
        }

        let engine = CleanvoicePolishEngine(
            apiKey: "cv-key", options: .defaults, session: makeStubSession(),
            pollInitialDelay: 0, pollInterval: 0
        )
        let stages = StateBox<[PolishProgress]>([])
        let bundleURL = episode
        let outputs = try await engine.run(
            bundleURL: bundleURL,
            speakers: ["host", "guest"].map {
                PolishSpeaker(id: $0, fileURL: bundleURL.appendingPathComponent("intermediate/\($0)/001_import.wav"))
            }
        ) { p in stages.mutate { $0.append(p) } }

        #expect(outputs == [
            PolishTrackOutput(trackID: "host", generationPath: "intermediate/host/002_polish.wav"),
            PolishTrackOutput(trackID: "guest", generationPath: "intermediate/guest/002_polish.wav"),
        ])
        #expect(stages.value.contains(.processing("EDITING 50%")))

        let bundle = try EpisodeBundle.open(at: episode)
        let host = try AudioIO.read(from: episode.appendingPathComponent("intermediate/host/002_polish.wav"))
        let guest = try AudioIO.read(from: episode.appendingPathComponent("intermediate/guest/002_polish.wav"))
        #expect(abs(host.duration - 1.5) < 0.01)
        #expect(abs(guest.duration - 1.25) < 0.01)
        // One Apply = one undo step across both speakers.
        let batches = Set(bundle.episode.operations.filter { $0.kind == "polish" }.map(\.batchID))
        #expect(batches.count == 1)

        let params = try JSONCoders.decode(
            OperationParamsRecord.self,
            from: episode.appendingPathComponent("intermediate/host/002_polish.params.json")
        )
        guard case .object(let dict) = params.params else {
            Issue.record("params missing"); return
        }
        #expect(dict["provider"] == .string("cleanvoice"))
    }

    /// Stub a single-speaker video run. `cutList` is the `timeline_audacity`
    /// body (nil ⇒ Cleanvoice returns no markers).
    private func stubVideoRun(cleaned: Data, cutList: String?, expectTimestamps: Bool) {
        let markers = cutList == nil
            ? "[]"
            : #"{"timeline_audacity":"https://cdn.example.com/timeline_audacity_x.txt?sig=1","timeline_edl":"https://cdn.example.com/x.edl"}"#
        CleanvoiceStubURLProtocol.responder = { req in
            switch (req.httpMethod ?? "", req.url?.path ?? "") {
            case ("POST", "/v2/upload"):
                return (200, self.json(#"{"signedUrl":"https://storage.example.com/u/host.wav?sig=1"}"#))
            case ("PUT", _):
                return (200, Data())
            case ("POST", "/v2/edits"):
                let body = try #require(try JSONSerialization.jsonObject(with: req.bodyData ?? Data()) as? [String: Any])
                let input = try #require(body["input"] as? [String: Any])
                #expect(input["upload_type"] == nil)  // single file: not multitrack
                let config = try #require(input["config"] as? [String: Any])
                #expect(config["muted"] as? Bool == false)  // video tracks are cut too
                #expect((config["export_timestamps"] as? Bool ?? false) == expectTimestamps)
                return (200, self.json(#"{"id":"edit_v"}"#))
            case ("GET", "/v2/edits/edit_v"):
                return (200, self.json(#"{"status":"SUCCESS","result":{"download_url":"https://cdn.example.com/host_clean.wav","timestamps_markers_urls":\#(markers)}}"#))
            case ("GET", "/host_clean.wav"):
                return (200, cleaned)
            case ("GET", "/timeline_audacity_x.txt"):
                return (200, Data((cutList ?? "").utf8))
            default:
                return (404, Data())
            }
        }
    }

    private func runSingleHost(_ episode: URL) async throws -> [PolishTrackOutput] {
        let engine = CleanvoicePolishEngine(
            apiKey: "k", options: .defaults, session: makeStubSession(),
            pollInitialDelay: 0, pollInterval: 0
        )
        return try await engine.run(
            bundleURL: episode,
            speakers: [PolishSpeaker(id: "host", fileURL: episode.appendingPathComponent("intermediate/host/001_import.wav"))]
        ) { _ in }
    }

    @Test
    func engineVideoTrackFollowsCutListTruedUpToCleanedLength() async throws {
        let workspace = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let episode = try makeEpisode(at: workspace, trackIDs: ["host"], video: true)
        // 2.0s in; the cut list says 0.50–1.05 (0.55s) was removed, but — as
        // observed live — the region includes a ~50 ms crossfade, so the
        // cleaned audio is 1.50s, not 1.45s.
        stubVideoRun(cleaned: try wavData(duration: 1.5), cutList: "0.5\t1.05\tDEADAIR\n", expectTimestamps: true)

        let outputs = try await runSingleHost(episode)
        #expect(outputs.map(\.generationPath) == ["intermediate/host/002_polish.wav"])

        let track = try #require(try EpisodeBundle.open(at: episode).track(withID: "host"))
        let edit = try #require(track.videoEdit)
        // Picture length matches the cleaned audio exactly…
        #expect(abs(edit.totalDuration - 1.5) < 1e-6)
        // …with the cut shrunk evenly around its interior: 0.525–1.025.
        #expect(edit.clips.count == 2)
        #expect(abs(edit.clips[0].sourceEnd - 0.525) < 1e-6)
        #expect(abs(edit.clips[1].sourceStart - 1.025) < 1e-6)
    }

    @Test
    func engineRefusesVideoCutsWithoutCutList() async throws {
        let workspace = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let episode = try makeEpisode(at: workspace, trackIDs: ["host"], video: true)
        stubVideoRun(cleaned: try wavData(duration: 1.5), cutList: nil, expectTimestamps: true)

        await #expect(throws: CleanvoiceError.self) { _ = try await runSingleHost(episode) }
        // Nothing written — no desynced generation.
        #expect(try EpisodeBundle.open(at: episode).track(withID: "host")?.current == "intermediate/host/001_import.wav")
    }

    @Test
    func engineRefusesCutListThatDoesNotExplainTheLength() async throws {
        let workspace = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let episode = try makeEpisode(at: workspace, trackIDs: ["host"], video: true)
        // One 0.1s region can't account for 2.0s → 1.0s.
        stubVideoRun(cleaned: try wavData(duration: 1.0), cutList: "0.5\t0.6\tDEADAIR\n", expectTimestamps: true)

        await #expect(throws: AuphonicCutList.CutListMismatch.self) { _ = try await runSingleHost(episode) }
        #expect(try EpisodeBundle.open(at: episode).track(withID: "host")?.current == "intermediate/host/001_import.wav")
    }

    @Test
    func engineSurfacesFailure() async throws {
        let workspace = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let episode = try makeEpisode(at: workspace, trackIDs: ["host"])

        CleanvoiceStubURLProtocol.responder = { req in
            switch (req.httpMethod ?? "", req.url?.path ?? "") {
            case ("POST", "/v2/upload"):
                return (200, self.json(#"{"signedUrl":"https://storage.example.com/u/host.wav"}"#))
            case ("PUT", _):
                return (200, Data())
            case ("POST", "/v2/edits"):
                return (200, self.json(#"{"id":"edit_f"}"#))
            default:
                return (200, self.json(#"{"status":"FAILURE","result":{"error":"Audio too short"}}"#))
            }
        }
        let engine = CleanvoicePolishEngine(
            apiKey: "k", options: .defaults, session: makeStubSession(),
            pollInitialDelay: 0, pollInterval: 0
        )
        do {
            _ = try await engine.run(
                bundleURL: episode,
                speakers: [PolishSpeaker(id: "host", fileURL: episode.appendingPathComponent("intermediate/host/001_import.wav"))]
            ) { _ in }
            Issue.record("expected failure")
        } catch let e as CleanvoiceError {
            #expect(e.description == "Cleanvoice edit edit_f failed — Audio too short")
        }
        // Nothing was written.
        #expect(try EpisodeBundle.open(at: episode).track(withID: "host")?.current == "intermediate/host/001_import.wav")
    }
}

// MARK: - PolishIngest

@Suite("PolishIngest")
struct PolishIngestTests {
    private func urls(_ names: [String]) -> [URL] {
        names.map { URL(fileURLWithPath: "/tmp/out/\($0)") }
    }

    @Test
    func assignMatchesDelimitedIDsPreferringLongest() {
        let map = PolishIngest.assign(
            files: urls(["maycast-ep_host2.wav", "abc_host.wav", "guest-cleaned.flac", "notes.txt"]),
            to: ["host", "host2", "guest"]
        )
        #expect(map["host"]?.lastPathComponent == "abc_host.wav")
        #expect(map["host2"]?.lastPathComponent == "maycast-ep_host2.wav")
        #expect(map["guest"]?.lastPathComponent == "guest-cleaned.flac")
    }

    @Test
    func loneSpeakerTakesLoneFileWhateverItsName() {
        let map = PolishIngest.assign(files: urls(["cleaned_episode.wav"]), to: ["host"])
        #expect(map["host"]?.lastPathComponent == "cleaned_episode.wav")
        // …but not when there's ambiguity.
        #expect(PolishIngest.assign(files: urls(["a.wav", "b.wav"]), to: ["host"]).isEmpty)
    }

    @Test
    func missingSpeakerFailsBeforeWritingAnything() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("maycast-ingest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let episode = dir.appendingPathComponent("ep.maycast")
        _ = try EpisodeBundle.create(at: episode)
        #expect(throws: PolishIngestError.self) {
            _ = try PolishIngest.writeGenerations(
                bundleURL: episode,
                speakers: [PolishSpeaker(id: "host", fileURL: dir.appendingPathComponent("x.wav"))],
                cleaned: [:],
                params: nil
            )
        }
    }
}

// MARK: - Stub

/// Same idea as `StubURLProtocol` in AuphonicClientTests, with its own
/// responder so the two serialized suites can run in parallel.
final class CleanvoiceStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responder: (@Sendable (StubURLProtocol.RecordedRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let recorded = StubURLProtocol.RecordedRequest(
            url: request.url,
            httpMethod: request.httpMethod,
            allHTTPHeaderFields: request.allHTTPHeaderFields,
            bodyData: request.httpBodyStream.flatMap { Self.drain($0) } ?? request.httpBody
        )
        do {
            guard let responder = Self.responder else {
                throw CleanvoiceError.unexpected("CleanvoiceStubURLProtocol.responder not set")
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
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let n = stream.read(&bytes, maxLength: bytes.count)
            if n <= 0 { break }
            buf.append(bytes, count: n)
        }
        return buf
    }
}

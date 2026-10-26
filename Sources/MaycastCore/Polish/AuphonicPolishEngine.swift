import Foundation

/// Settings for an Auphonic multitrack production. Mirrors the algorithm
/// fields described at https://auphonic.com/help/api/multitrack.html .
public struct AuphonicPolishOptions: Equatable, Sendable {
    /// Auphonic denoise modes — passed through as-is in the algorithms payload.
    /// `dynamic` is the default for spoken-word podcasts.
    public enum DenoiseMethod: String, CaseIterable, Sendable, Equatable {
        case dynamic
        case staticMode = "static"
        case speechIsolation = "speech_isolation"
    }

    /// Allowed Auphonic debreath values (dB attenuation, or 0 = off).
    /// `100` is "maximum" in Auphonic's docs.
    public enum DebreathAmount: Int, CaseIterable, Sendable, Equatable {
        case off = 0
        case db3 = 3
        case db6 = 6
        case db9 = 9
        case db12 = 12
        case db15 = 15
        case db18 = 18
        case db24 = 24
        case db30 = 30
        case db36 = 36
        case max = 100
    }

    // Loudness
    public var loudnessTarget: Double  // LUFS, range -23..-14 (Auphonic accepts wider but this keeps the UI sensible)

    // Adaptive leveler (per-track auto level)
    public var levelerEnabled: Bool

    // Denoise
    public var denoiseEnabled: Bool
    public var denoiseMethod: DenoiseMethod

    // Cuts
    public var fillerCutterEnabled: Bool
    public var silenceCutterEnabled: Bool
    public var coughCutterEnabled: Bool

    // Breath / sniffle attenuation
    public var debreathAmount: DebreathAmount

    // High-pass filter to remove low-frequency rumble. Auphonic recommends on.
    public var hipfilterEnabled: Bool

    // When true, the production is left on Auphonic's dashboard after a
    // successful run instead of being deleted. Useful for diagnosing why a
    // track came out unexpectedly (silence, low level, etc.).
    public var keepProduction: Bool

    public init(
        loudnessTarget: Double,
        levelerEnabled: Bool,
        denoiseEnabled: Bool,
        denoiseMethod: DenoiseMethod,
        fillerCutterEnabled: Bool,
        silenceCutterEnabled: Bool,
        coughCutterEnabled: Bool,
        debreathAmount: DebreathAmount,
        hipfilterEnabled: Bool,
        keepProduction: Bool
    ) {
        self.loudnessTarget = loudnessTarget
        self.levelerEnabled = levelerEnabled
        self.denoiseEnabled = denoiseEnabled
        self.denoiseMethod = denoiseMethod
        self.fillerCutterEnabled = fillerCutterEnabled
        self.silenceCutterEnabled = silenceCutterEnabled
        self.coughCutterEnabled = coughCutterEnabled
        self.debreathAmount = debreathAmount
        self.hipfilterEnabled = hipfilterEnabled
        self.keepProduction = keepProduction
    }

    public static let defaults = AuphonicPolishOptions(
        loudnessTarget: -16,
        levelerEnabled: true,
        denoiseEnabled: true,
        denoiseMethod: .dynamic,
        fillerCutterEnabled: true,
        silenceCutterEnabled: true,
        coughCutterEnabled: true,
        debreathAmount: .max,
        hipfilterEnabled: true,
        keepProduction: false
    )

    var cuttersOn: Bool { fillerCutterEnabled || silenceCutterEnabled || coughCutterEnabled }
}

/// Polish via the Auphonic Multitrack API: one production with every speaker
/// as a separate track, per-track WAVs back as a ZIP, plus a cut list when the
/// cutters are on (replayed onto video tracks so picture follows the audio).
public struct AuphonicPolishEngine: PolishEngine {
    public let provider: PolishProvider = .auphonic

    private let apiKey: String
    private let options: AuphonicPolishOptions
    private let session: URLSession?

    public init(apiKey: String, options: AuphonicPolishOptions, session: URLSession? = nil) {
        self.apiKey = apiKey
        self.options = options
        self.session = session
    }

    public func run(
        bundleURL: URL,
        speakers: [PolishSpeaker],
        onProgress: @Sendable @escaping (PolishProgress) -> Void
    ) async throws -> [PolishTrackOutput] {
        let client = AuphonicClient(apiKey: apiKey, session: session)

        // 1) Create production
        let payload = Self.makePayload(options: options, speakers: speakers, bundleURL: bundleURL)
        let production = try await client.createProduction(payload: payload)
        let uuid = production.uuid

        // 2) Upload tracks. We don't have per-byte upload progress; mark each
        //    track as 1.0 after its upload completes.
        var uploadProgress = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, 0.0) })
        onProgress(.uploading(uploadProgress))
        for sp in speakers {
            try Task.checkCancellation()
            try await client.uploadTrack(uuid: uuid, trackID: sp.id, fileURL: sp.fileURL)
            uploadProgress[sp.id] = 1.0
            onProgress(.uploading(uploadProgress))
        }

        // 3) Start
        _ = try await client.startProduction(uuid: uuid)

        // 4) Poll. Status strings change as Auphonic moves through phases.
        //    If anything from here on fails, the production is left on
        //    Auphonic so the user can inspect it.
        onProgress(.processing("starting"))
        let done = try await client.pollUntilDone(uuid: uuid) { tick in
            onProgress(.processing(tick.statusString ?? "running"))
        }

        // 5) Find the per-track ZIP output.
        guard let tracksOutput = done.outputFiles?.first(where: { $0.format == "tracks" }),
              let downloadURLString = tracksOutput.downloadURL,
              let downloadURL = URL(string: downloadURLString)
        else {
            throw AuphonicError.unexpected("Auphonic returned no per-track ZIP output")
        }

        // 6) Download the tracks ZIP (with progress).
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("auphonic-\(uuid)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let zipURL = tmpDir.appendingPathComponent("tracks.zip")
        let speakerIDs = speakers.map(\.id)
        onProgress(.downloading(Dictionary(uniqueKeysWithValues: speakerIDs.map { ($0, 0.0) })))
        try await client.download(from: downloadURL, to: zipURL) { p in
            onProgress(.downloading(Dictionary(uniqueKeysWithValues: speakerIDs.map { ($0, p) })))
        }

        // 6b) If a cut list was produced (cutters were on), download + parse it
        //     into the removed regions on the input timeline. We replay these
        //     onto each speaker's video so the picture follows Auphonic's cuts.
        var removedRegions: [AuphonicCutList.Region] = []
        if let cutListOutput = done.outputFiles?.first(where: {
            $0.format == "cut-list" || ($0.ending?.localizedCaseInsensitiveContains("audacity") ?? false)
        }), let urlString = cutListOutput.downloadURL, let cutListURL = URL(string: urlString) {
            let dest = tmpDir.appendingPathComponent("cuts.txt")
            try await client.download(from: cutListURL, to: dest) { _ in }
            if let text = try? String(contentsOf: dest, encoding: .utf8) {
                removedRegions = AuphonicCutList.parseAudacityRegions(text)
            }
        }

        // 7) Unzip and write one polish generation per track.
        let extracted = try ZipExtractor.extract(archive: zipURL, to: tmpDir.appendingPathComponent("unzipped"))
        let outputs = try PolishIngest.writeGenerations(
            bundleURL: bundleURL,
            speakers: speakers,
            cleaned: PolishIngest.assign(files: extracted.extractedFiles, to: speakerIDs),
            videoCut: { sp, _ in
                guard !removedRegions.isEmpty else { return nil }
                let inputDuration = (try? AudioIO.probeDuration(of: sp.fileURL)) ?? 0
                return AuphonicCutList.keptArrangement(removed: removedRegions, totalDuration: inputDuration)
            },
            params: Self.makeParamsJSON(options: options),
            returnedFiles: extracted.extractedFiles
        )

        // 8) Best-effort cleanup of the Auphonic production. Skipped when
        //    `keepProduction` is on so the user can inspect the run on
        //    Auphonic's dashboard. Failures are non-fatal either way — the
        //    audio is already saved locally.
        if !options.keepProduction {
            try? await client.deleteProduction(uuid: uuid)
        }
        return outputs
    }

    static func makePayload(
        options: AuphonicPolishOptions,
        speakers: [PolishSpeaker],
        bundleURL: URL
    ) -> Auphonic.ProductionPayload {
        let perTrackBreath = options.debreathAmount != .off
        let multi: [Auphonic.MultiInputFile] = speakers.map { sp in
            var entry = Auphonic.MultiInputFile(type: "multitrack", id: sp.id)
            // Force every speaker track to be treated as foreground so the
            // Adaptive Leveler doesn't auto-detect a quieter speaker as
            // background and duck them into near-silence.
            var algos = Auphonic.Algorithms(backforeground: "foreground")
            if perTrackBreath {
                algos.debreathAmount = Double(options.debreathAmount.rawValue)
            }
            entry.algorithms = algos
            return entry
        }

        var algorithms = Auphonic.Algorithms(
            fadetime: 250,
            loudnessTarget: options.loudnessTarget,
            hipfilter: options.hipfilterEnabled
        )
        if options.levelerEnabled { algorithms.leveler = true }
        if options.denoiseEnabled {
            algorithms.denoise = true
            algorithms.denoiseMethod = options.denoiseMethod.rawValue
        }
        if options.cuttersOn {
            algorithms.cutMode = "apply_cuts"
            if options.fillerCutterEnabled { algorithms.fillerCutter = true }
            if options.silenceCutterEnabled { algorithms.silenceCutter = true }
            if options.coughCutterEnabled { algorithms.coughCutter = true }
        }

        var outputs: [Auphonic.OutputFile] = [
            // We always ask for a cheap mp3 master (Auphonic requires at least
            // one master output) — Maycast's own Mix flow does the final mix,
            // so we never actually download this file.
            Auphonic.OutputFile(format: "mp3"),
            Auphonic.OutputFile(format: "tracks", ending: "wav.zip"),
        ]
        if options.cuttersOn {
            // Cut list of the removed (filler / silence / cough) regions on the
            // input timeline. We replay these cuts onto each speaker's video so
            // the picture stays in sync with the cleaned audio. Harmless for
            // audio-only episodes (we just don't download it).
            outputs.append(Auphonic.OutputFile(format: "cut-list", ending: "AudacityRegions.txt"))
        }

        let title = "maycast-\(bundleURL.deletingPathExtension().lastPathComponent)-\(ISO8601DateFormatter().string(from: Date()))"
        return Auphonic.ProductionPayload(
            isMultitrack: true,
            metadata: Auphonic.ProductionPayload.Metadata(title: title),
            multiInputFiles: multi,
            algorithms: algorithms,
            outputFiles: outputs
        )
    }

    static func makeParamsJSON(options: AuphonicPolishOptions) -> JSONValue {
        .object([
            "provider": .string(PolishProvider.auphonic.rawValue),
            "loudness": .number(options.loudnessTarget),
            "leveler": .bool(options.levelerEnabled),
            "denoise": .bool(options.denoiseEnabled),
            "denoise_method": .string(options.denoiseMethod.rawValue),
            "filler_cutter": .bool(options.fillerCutterEnabled),
            "silence_cutter": .bool(options.silenceCutterEnabled),
            "cough_cutter": .bool(options.coughCutterEnabled),
            "debreath_amount": .integer(options.debreathAmount.rawValue),
            "hipfilter": .bool(options.hipfilterEnabled),
        ])
    }
}
